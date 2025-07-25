{-# LANGUAGE OverloadedStrings, GeneralizedNewtypeDeriving, TupleSections #-}
{-# LANGUAGE DeriveFunctor, LambdaCase, ViewPatterns #-}

module DateParser
       ( DateFormat
       , parseDateFormat
       , german

       , parseDate
       , parseDateWithToday

       , parseHLDate
       , parseHLDateWithToday

       , printDate

       -- * Utilities
       , weekDay
       ) where

import           Control.Applicative hiding (many, some)
import           Data.List
import           Data.Maybe
import           Data.Monoid
import           Data.Ord
import qualified Data.Semigroup as Sem
import           Data.Void

import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import           Data.Text.Lazy.Builder (Builder, toLazyText)
import qualified Data.Text.Lazy.Builder as Build
import qualified Data.Text.Lazy.Builder.Int as Build
import           Data.Time.Ext
import           Data.Time.Calendar.WeekDate
import qualified Hledger.Data.Dates as HL
import qualified Hledger.Data.Types as HL
import           Text.Megaparsec
import           Text.Megaparsec.Char
import           Text.Printf (printf, PrintfArg)

newtype DateFormat = DateFormat [DateSpec]
                   deriving (Eq, Show)

-- TODO Add show instance that corresponds to parsed expression

data DateSpec = DateYear
              | DateYearShort
              | DateMonth
              | DateDay
              | DateString Text
              | DateOptional [DateSpec]
                deriving (Show, Eq)


parseHLDate :: Day -> Text -> Either Text Day
parseHLDate current text = case parse HL.smartdate "date" text of
  Right res -> case HL.fixSmartDate current res of
    HL.Exact day -> Right day
    HL.Flex day -> Left $ "Date " <> T.pack (show day) <> " not specified exactly."
  Left err -> Left $ T.pack $ errorBundlePretty err

parseHLDateWithToday :: Text -> IO (Either Text Day)
parseHLDateWithToday text = flip parseHLDate text <$> getLocalDay

-- | Corresponds to %d[.[%m[.[%y]]]]
german :: DateFormat
german = DateFormat
  [ DateDay
  , DateOptional [DateString "."
                 ,DateOptional [DateMonth
                               ,DateOptional [DateString "."
                                             ,DateOptional [DateYearShort]]]]]

parseDateFormat :: Text -> Either Text DateFormat
parseDateFormat text = case parse dateSpec "date-format" text of
  Left err  -> Left $ T.pack $ errorBundlePretty err
  Right res -> Right res


type Parser = Parsec Void Text

dateSpec :: Parser DateFormat
dateSpec = DateFormat <$> (many oneTok <* eof)

oneTok :: Parser DateSpec
oneTok =  char '%' *> percent
      <|> char '\\' *> escape
      <|> DateOptional <$> between (char '[') (char ']') (many oneTok)
      <|> DateString . T.pack <$> some (noneOf ("\\[]%" :: String))

percent :: Parser DateSpec
percent =  char 'y' *> pure DateYearShort
       <|> char 'Y' *> pure DateYear
       <|> char 'm' *> pure DateMonth
       <|> char 'd' *> pure DateDay
       <|> char '%' *> pure (DateString "%")

escape :: Parser DateSpec
escape =  char '\\' *> pure (DateString "\\")
      <|> char '[' *> pure (DateString "[")
      <|> char ']' *> pure (DateString "]")

-- | Parse text with given format and fill in missing fields with todays date.
parseDateWithToday :: DateFormat -> Text -> IO (Either Text Day)
parseDateWithToday spec text = do
  today <- getLocalDay
  return (parseDate today spec text)

parseDate :: Day -> DateFormat -> Text -> Either Text Day
parseDate current (DateFormat spec) text =
  let en = Just <$> parseEnglish current
      completeIDate :: IncompleteDate (Maybe Int) -> Maybe Day
      completeIDate d =
        completeNearDate Past current d
        <|> completeNearDate Future current d
      num = completeIDate . fmap getFirst <$> parseDate' spec <* eof

  in case parse ((try en <|> num) <* eof) "date" text of
    Left err -> Left $ T.pack $ errorBundlePretty err
    Right Nothing -> Left "Invalid Date"
    Right (Just d) -> Right d

-- (y, m, d)
newtype IncompleteDate a = IDate (a, a, a)
                       deriving (Sem.Semigroup, Monoid, Functor, Show)

data Direction = Future | Past deriving (Eq,Show)
-- find a date that matches the incomplete date and is as near as possible to
-- the current date in the given direction (Future means only today and in the
-- future; Past means only today and in the past).
completeNearDate :: Direction -> Day  -> IncompleteDate (Maybe Int) -> Maybe Day
completeNearDate dir current (IDate (i_year,i_month,i_day)) =
  let
    sign = if dir == Past then -1 else 1
    (currentYear, _, _) = toGregorian current
    singleton a = [a]
    withDefaultRange :: Maybe a -> [a] -> [a]
    withDefaultRange maybe_value range =
      fromMaybe
        (if dir == Past then reverse range else range)
        (singleton <$> maybe_value)
  in listToMaybe $ do
    -- every date occours at least once in 8 years
    -- That is because the years divisible by 100 but not by 400 are no leap
    -- years. Depending on dir, choose the past or the next 8 years
    y <- (toInteger <$> i_year) `withDefaultRange`
            [currentYear + sign*4 - 4 .. currentYear + sign*4 + 4]
    m <- i_month  `withDefaultRange` [1..12]
    d <- i_day    `withDefaultRange` [1..31]
    completed <- maybeToList (fromGregorianValid y m d)
    if ((completed `diffDays` current) * sign >= 0)
    then return completed
    else fail $ "Completed day not the " ++ show dir ++ "."


parseDate' :: [DateSpec] -> Parser (IncompleteDate (First Int))
parseDate' [] = return mempty
parseDate' (d:ds) = case d of
  DateOptional sub -> try ((<>) <$> parseDate' sub <*> parseDate' ds)
                  <|> parseDate' ds

  _ -> (<>) <$> parseDate1 d <*> parseDate' ds


parseDate1 :: DateSpec -> Parser (IncompleteDate (First Int))
parseDate1 ds = case ds of
  DateYear      -> part (,mempty,mempty)
  DateYearShort -> part $ (,mempty,mempty) . fmap completeYear
  DateMonth     -> part (mempty,,mempty)
  DateDay       -> part (mempty,mempty,)
  DateString s  -> string s >> pure mempty
  DateOptional ds' -> option mempty (try $ parseDate' ds')

  where digits = some digitChar
        part f = IDate . f . First . Just . (read :: String -> Int)  <$> digits
        completeYear year
          | year < 100 = year + 2000
          | otherwise  = year


-- Parses an english word such as 'yesterday' or 'monday'
parseEnglish :: Day -> Parser Day
parseEnglish current = ($ current) <$> choice (relativeDays ++ weekDays)

relativeDays :: [Parser (Day -> Day)]
relativeDays = map try
  [ addDays 1    <$ string "tomorrow"
  , addDays 1    <$ string "tom"
  , id           <$ string "today"
  , id           <$ string "tod"
  , addDays (-1) <$ string "yesterday"
  , addDays (-1) <$ string "yest"
  , addDays (-1) <$ string "yes"
  , addDays (-1) <$ string "ye"
  , addDays (-1) <$ string "y"
  ]

weekDays :: [Parser (Day -> Day)]
weekDays = map (\(i, name) -> weekDay i <$ try (string name)) sortedDays
  where -- sort the days so that the parser finds the longest match
        sortedDays :: [(Int, Text)]
        sortedDays = sortOn (Down . T.length . snd) flattenedDays
        flattenedDays :: [(Int, Text)]
        flattenedDays = concatMap (\(i, xs) -> fmap (i,) xs) days
        days :: [(Int, [Text])]
        days = [ (1, ["monday", "m", "mo", "mon"])
               , (2, ["tuesday", "tu", "tue", "tues"])
               , (3, ["wednesday", "w", "we", "wed"])
               , (4, ["thursday", "th", "thu", "thur"])
               , (5, ["friday", "f", "fr", "fri"])
               , (6, ["saturday", "sa", "sat"])
               , (7, ["sunday", "su", "sun"])
               ]

-- | Computes a relative date by the given weekday
--
-- Returns the first weekday with index wday, that's before the current date.
weekDay :: Int -> Day -> Day
weekDay wday current =
  let (_, _, wday') = toWeekDate current
      difference = negate $ (wday' - wday) `mod` 7
  in addDays (toInteger difference) current


printDate :: DateFormat -> Day -> Text
printDate (DateFormat spec) day = TL.toStrict $ toLazyText $ printDate' spec day

printDate' :: [DateSpec] -> Day -> Builder
printDate' [] _ = ""
printDate' (DateYear:ds) day@(toGregorian -> (y,_,_)) =
  Build.decimal y <> printDate' ds day
printDate' (DateYearShort:ds) day@(toGregorian -> (y,_,_))
  | y > 2000  = twoDigits (y-2000) <> printDate' ds day
  | otherwise = twoDigits y <> printDate' ds day
printDate' (DateMonth:ds) day@(toGregorian -> (_,m,_)) =
  twoDigits m <> printDate' ds day
printDate' (DateDay:ds) day@(toGregorian -> (_,_,d)) =
  twoDigits d <> printDate' ds day
printDate' (DateString s:ds) day =
  Build.fromText s <> printDate' ds day
printDate' (DateOptional opt:ds) day =
  printDate' opt day <> printDate' ds day

twoDigits :: (Integral a, PrintfArg a) => a -> Builder
twoDigits = Build.fromString . printf "%02d"
