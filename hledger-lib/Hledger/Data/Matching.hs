{-|

More generic matching, done in one step, unlike FilterSpec and filterJournal*. 
Currently used only by hledger-web.

-}

module Hledger.Data.Matching
where
import Data.List
-- import Data.Map (findWithDefault, (!))
import Data.Maybe
-- import Data.Ord
import Data.Time.Calendar
-- import Data.Time.LocalTime
-- import Data.Tree
import Safe (readDef, headDef)
-- import System.Time (ClockTime(TOD))
import Test.HUnit
import Text.ParserCombinators.Parsec
-- import Text.Printf
-- import qualified Data.Map as Map

import Hledger.Utils
import Hledger.Data.Types
-- import Hledger.Data.AccountName
-- import Hledger.Data.Amount
-- import Hledger.Data.Commodity (canonicaliseCommodities)
import Hledger.Data.Dates
-- import Hledger.Data.Transaction (journalTransactionWithDate,balanceTransaction)
-- import Hledger.Data.Posting
-- import Hledger.Data.TimeLog

-- | A matcher is an arbitrary boolean expression of various search criteria.
-- It can be used to match postings, transactions, accounts and more.
-- If the first boolean is False, it's an inverse match.
-- Currently used by hledger-web, will probably also replace FilterSpec at some point.
data Matcher = MatchAny                   -- ^ always match
             | MatchNone                  -- ^ never match
             | MatchOr [Matcher]          -- ^ match if any of these match
             | MatchAnd [Matcher]         -- ^ match if all of these match
             | MatchDesc Bool String      -- ^ match if description matches this regexp
             | MatchAcct Bool String      -- ^ match postings whose account matches this regexp
             | MatchDate Bool DateSpan    -- ^ match if actual date in this date span
             | MatchEDate Bool DateSpan   -- ^ match if effective date in this date span
             | MatchStatus Bool Bool      -- ^ match if cleared status has this value
             | MatchReal Bool Bool        -- ^ match if "realness" (involves a real non-virtual account ?) has this value
             | MatchEmpty Bool Bool       -- ^ match if "emptiness" (amount is zero ?) has this value
             | MatchDepth Bool Int        -- ^ match if account depth is less than or equal to this value
             -- XXX not sure if this belongs here
             | MatchInAcct Bool String    -- ^ a flag indicating account register mode
    deriving (Show, Eq)

-- | Convert a query expression containing zero or more space-separated
-- search terms to a matcher and list of modifiers (TODO). A search term is either:
--
-- 1. a match criteria, used to select transactions. This is usually a prefixed pattern such as:
--    - acct:REGEXP
--    - date:PERIODEXP
--    - not:desc:REGEXP
--
-- 2. a modifier, that changes behaviour in some other way. There is currently one of these:
--    - inacct:FULLACCTNAME - should appear only once
--
-- When a pattern contains spaces, it or the whole term should be enclosed in single or double quotes.
-- Multiple terms are AND'ed together.
-- A reference date is required to interpret relative dates in period expressions.
--
-- parseMatcher :: Day -> String -> (Matcher,[Modifier])
parseMatcher :: Day -> String -> Matcher
parseMatcher refdate s = m
  where
    m = case ms of []     -> MatchAny
                   (m:[]) -> m
                   ms     -> MatchAnd ms
    ms = map parseword $ words'' matcherprefixes s

    -- keep synced with patterns below
    matcherprefixes = map (++":") [
                       "desc","acct","inacct","in","date","edate","status","real","empty","depth"]

    parseword :: String -> Matcher
    parseword ('n':'o':'t':':':s) = negateMatch $ parseMatcher refdate $ quoteIfSpaced s
    parseword ('d':'e':'s':'c':':':s) = MatchDesc True s
    parseword ('a':'c':'c':'t':':':s) = MatchAcct True s
    parseword ('i':'n':'a':'c':'c':'t':':':s) = MatchInAcct True s
    parseword ('i':'n':':':s)                 = MatchInAcct True s
    parseword ('d':'a':'t':'e':':':s) =
        case parsePeriodExpr refdate s of Left _ -> MatchNone -- XXX warn
                                          Right (_,span) -> MatchDate True span
    parseword ('e':'d':'a':'t':'e':':':s) =
        case parsePeriodExpr refdate s of Left _ -> MatchNone -- XXX warn
                                          Right (_,span) -> MatchEDate True span
    parseword ('s':'t':'a':'t':'u':'s':':':s) = MatchStatus True $ parseStatus s
    parseword ('r':'e':'a':'l':':':s) = MatchReal True $ parseBool s
    parseword ('e':'m':'p':'t':'y':':':s) = MatchEmpty True $ parseBool s
    parseword ('d':'e':'p':'t':'h':':':s) = MatchDepth True $ readDef 0 s
    parseword "" = MatchAny
    parseword s = parseword $ "acct:"++s

    parseStatus "*" = True
    parseStatus _ = False

    parseBool s = s `elem` ["t","true","1","on"]

-- | Quote-and-prefix-aware version of words - don't split on spaces which
-- are inside quotes, including quotes which may have one of the specified
-- prefixes in front, and maybe an additional not: prefix in front of that.
words'' :: [String] -> String -> [String]
words'' prefixes = fromparse . parsewith maybeprefixedquotedphrases -- XXX
    where
      maybeprefixedquotedphrases = choice' [prefixedQuotedPattern, quotedPattern, pattern] `sepBy` many1 spacenonewline
      prefixedQuotedPattern = do
        not' <- optionMaybe $ string "not:"
        prefix <- choice' $ map string prefixes
        p <- quotedPattern
        return $ fromMaybe "" not' ++ prefix ++ stripquotes p
      quotedPattern = do
        p <- between (oneOf "'\"") (oneOf "'\"") $ many $ noneOf "'\""
        return $ stripquotes p
      pattern = many (noneOf " \n\r\"")

-- -- | Parse the query string as a boolean tree of match patterns.
-- parseMatcher :: String -> Matcher
-- parseMatcher s = either (const (MatchAny)) id $ runParser matcher () "" $ lexmatcher s

-- lexmatcher :: String -> [String]
-- lexmatcher s = words' s

-- matcher :: GenParser String () Matcher
-- matcher = undefined

-- | Convert a match expression to its inverse.
negateMatch :: Matcher -> Matcher
negateMatch MatchAny                   = MatchNone
negateMatch MatchNone                  = MatchAny
negateMatch (MatchOr ms)               = MatchAnd $ map negateMatch ms
negateMatch (MatchAnd ms)              = MatchOr $ map negateMatch ms
negateMatch (MatchAcct sense arg)      = MatchAcct (not sense) arg
negateMatch (MatchDesc sense arg)      = MatchDesc (not sense) arg
negateMatch (MatchInAcct sense arg)    = MatchInAcct (not sense) arg
negateMatch (MatchDate sense arg)      = MatchDate (not sense) arg
negateMatch (MatchEDate sense arg)     = MatchEDate (not sense) arg
negateMatch (MatchStatus sense arg)    = MatchStatus (not sense) arg
negateMatch (MatchReal sense arg)      = MatchReal (not sense) arg
negateMatch (MatchEmpty sense arg)     = MatchEmpty (not sense) arg
negateMatch (MatchDepth sense arg)     = MatchDepth (not sense) arg

-- | Does the match expression match this posting ?
matchesPosting :: Matcher -> Posting -> Bool
matchesPosting (MatchAny) _ = True
matchesPosting (MatchNone) _ = False
matchesPosting (MatchOr ms) p = any (`matchesPosting` p) ms
matchesPosting (MatchAnd ms) p = all (`matchesPosting` p) ms
matchesPosting (MatchDesc True r) p = regexMatchesCI r $ maybe "" tdescription $ ptransaction p
matchesPosting (MatchDesc False r) p = not $ (MatchDesc True r) `matchesPosting` p
matchesPosting (MatchAcct True r) p = regexMatchesCI r $ paccount p
matchesPosting (MatchAcct False r) p = not $ (MatchAcct True r) `matchesPosting` p
matchesPosting (MatchInAcct True _) _ = True
    -- case ptransaction p of
    --     Just t -> (MatchAcct True r) `matchesTransaction` t && (MatchAcct False r) `matchesPosting` p
    --     Nothing -> False
-- matchesPosting (MatchInAcct False r) p = not $ (MatchInAcct True r) `matchesPosting` p
matchesPosting (MatchDate True span) p =
    case d of Just d'  -> spanContainsDate span d'
              Nothing -> False
    where d = maybe Nothing (Just . tdate) $ ptransaction p
matchesPosting (MatchDate False span) p = not $ (MatchDate True span) `matchesPosting` p
matchesPosting (MatchEDate True span) p =
    case d of Just d  -> spanContainsDate span d
              Nothing -> False
    where d = maybe Nothing teffectivedate $ ptransaction p
matchesPosting (MatchEDate False span) p = not $ (MatchEDate True span) `matchesPosting` p
matchesPosting _ _ = False

-- | Does the match expression match this transaction ?
matchesTransaction :: Matcher -> Transaction -> Bool
matchesTransaction (MatchAny) _ = True
matchesTransaction (MatchNone) _ = False
matchesTransaction (MatchOr ms) t = any (`matchesTransaction` t) ms
matchesTransaction (MatchAnd ms) t = all (`matchesTransaction` t) ms
matchesTransaction (MatchDesc True r) t = regexMatchesCI r $ tdescription t
matchesTransaction (MatchDesc False r) t = not $ (MatchDesc True r) `matchesTransaction` t
matchesTransaction m@(MatchAcct True _) t = any (m `matchesPosting`) $ tpostings t
matchesTransaction (MatchAcct False r) t = not $ (MatchAcct True r) `matchesTransaction` t
matchesTransaction (MatchInAcct sense r) t = (MatchAcct sense r) `matchesTransaction` t
matchesTransaction (MatchDate True span) t = spanContainsDate span $ tdate t
matchesTransaction (MatchDate False span) t = not $ (MatchDate True span) `matchesTransaction` t
matchesTransaction (MatchEDate True span) Transaction{teffectivedate=Just d} = spanContainsDate span d
matchesTransaction _ Transaction{teffectivedate=Nothing} = False
matchesTransaction (MatchEDate False span) t = not $ (MatchEDate True span) `matchesTransaction` t
matchesTransaction _ _ = False

-- | Does the match expression match this account ?
-- A matching in: clause is also considered a match.
matchesAccount :: Matcher -> AccountName -> Bool
matchesAccount (MatchAny) _ = True
matchesAccount (MatchNone) _ = False
matchesAccount (MatchOr ms) a = any (`matchesAccount` a) ms
matchesAccount (MatchAnd ms) a = all (`matchesAccount` a) ms
matchesAccount (MatchAcct True r) a = regexMatchesCI r a
matchesAccount (MatchAcct False r) a = not $ (MatchAcct True r) `matchesAccount` a
matchesAccount (MatchInAcct True r) a = (MatchAcct True r) `matchesAccount` a
matchesAccount _ _ = False

-- | Does the match expression include an "in:" clause specifying this account ?
-- For now, does a case-insensitive exact string match on the full account name.
-- XXX perhaps in: should be handled separately.
matchesInAccount :: Matcher -> AccountName -> Bool
matchesInAccount (MatchAny) _ = True
matchesInAccount (MatchNone) _ = False
matchesInAccount (MatchOr ms) a = any (`matchesInAccount` a) ms
matchesInAccount (MatchAnd ms) a = all (`matchesInAccount` a) ms
matchesInAccount (MatchInAcct True s) a = lowercase s == lowercase a -- regexMatchesCI r a
matchesInAccount (MatchInAcct False s) a = not $ (MatchInAcct True s) `matchesInAccount` a
matchesInAccount _ _ = True

-- | Which account is specified by an in:ACCT in the match expression, if any ?
matcherInAccount :: Matcher -> Maybe AccountName
matcherInAccount (MatchOr ms) = case catMaybes $ map matcherInAccount ms of
                                  [a] -> Just a
                                  (a:as@(_:_)) -> if all (==a) as then Just a else Nothing
                                  _ -> Nothing
matcherInAccount (MatchAnd ms) = headDef Nothing $ map Just $ catMaybes $ map matcherInAccount ms
matcherInAccount (MatchInAcct True a) = Just a
matcherInAccount _ = Nothing

-- | What start date does this matcher specify, if any ?
-- If the matcher is an OR expression, returns the earliest of the alternatives.
matcherStartDate :: Matcher -> Maybe Day
matcherStartDate (MatchOr ms) = earliestMaybeDate $ map matcherStartDate ms
matcherStartDate (MatchAnd ms) = latestMaybeDate $ map matcherStartDate ms
matcherStartDate (MatchDate True (DateSpan (Just d) _)) = Just d
matcherStartDate _ = Nothing

-- | What is the earliest of these dates, where Nothing is earliest ?
earliestMaybeDate :: [Maybe Day] -> Maybe Day
earliestMaybeDate = headDef Nothing . sortBy compareMaybeDates

-- | What is the latest of these dates, where Nothing is earliest ?
latestMaybeDate :: [Maybe Day] -> Maybe Day
latestMaybeDate = headDef Nothing . sortBy (flip compareMaybeDates)

-- | Compare two maybe dates, Nothing is earliest.
compareMaybeDates :: Maybe Day -> Maybe Day -> Ordering
compareMaybeDates Nothing Nothing = EQ
compareMaybeDates Nothing (Just _) = LT
compareMaybeDates (Just _) Nothing = GT
compareMaybeDates (Just a) (Just b) = compare a b

tests_Hledger_Data_Matching :: Test
tests_Hledger_Data_Matching = TestList
 [

  "parseMatcher" ~: do
    let d = parsedate "2011/1/1"
    parseMatcher d "a" `is` (MatchAcct True "a")
    parseMatcher d "acct:a" `is` (MatchAcct True "a")
    parseMatcher d "acct:a desc:b" `is` (MatchAnd [MatchAcct True "a", MatchDesc True "b"])
    parseMatcher d "\"acct:expenses:autres d\233penses\"" `is` (MatchAcct True "expenses:autres d\233penses")
    parseMatcher d "not:desc:'a b'" `is` (MatchDesc False "a b")

    parseMatcher d "inacct:a desc:b" `is` (MatchAnd [MatchInAcct True "a", MatchDesc True "b"])
    parseMatcher d "inacct:a inacct:b" `is` (MatchAnd [MatchInAcct True "a", MatchInAcct True "b"])

  ,"matchesAccount" ~: do
    assertBool "positive acct match" $ matchesAccount (MatchAcct True "b:c") "a:bb:c:d"
    -- assertBool "acct should match at beginning" $ not $ matchesAccount (MatchAcct True "a:b") "c:a:b"

  -- ,"matchesAccount" ~: do
  --   matchesAccount (MatchAcct )
 ]