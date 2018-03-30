{-# LANGUAGE ConstraintKinds        #-}
{-# LANGUAGE FlexibleContexts       #-}
{-# LANGUAGE FlexibleInstances      #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE RankNTypes             #-}
{-# LANGUAGE StandaloneDeriving     #-}
module Grammar.Types
       ( Weight
       , Grammar, Rule (..), Head, Activation, Body, Terminal
       , Term (..), Expand (..), Grammarly
       , runGrammar, always, (/\), (\/)
       , (-|), (-||), ($:), (|$:), (|->), (%:)
       ) where

import Control.Arrow       (first)
import System.Random
import Text.Show.Functions ()

import Generate (Weight)
import Music

{- Operators' precedence. -}
infix 6 %:
infix 5 $:
infix 5 |$:
infixr 4 :-:
infix 3 :->
infix 3 |->

{- Grammar datatypes. -}
type Grammar meta a = [Rule meta a]
data Rule meta a = Head a :-> Body meta a
type Head a = (a, Weight, Activation)
type Activation = Duration -> Bool
type Body meta a = Duration -> Term meta a
type Terminal a = (a, Duration)

data Term meta a = -- primitive
                   Prim (Terminal a)
                   -- sequence
                   | Term meta a :-: Term meta a
                   -- auxiliary modifications
                   | Aux Bool meta (Term meta a)
                   -- let (enables repetition)
                   | Let (Term meta a) (forall b. Term () b -> Term () b)

deriving instance (Show a, Show meta) => Show (Term meta a)

instance Functor (Term meta) where
  fmap f m = case m of
    Prim p             -> Prim (first f p)
    m1 :-: m2          -> (f <$> m1) :-: (f <$> m2)
    Aux frozen meta m1 -> Aux frozen meta (f <$> m1)
    Let m1 k           -> Let (f <$> m1) k

instance (Eq a, Eq meta) => Eq (Term meta a) where
  (Prim (a, d))  == (Prim (a', d'))   = a == a' && d == d'
  (x :-: y)      == (x' :-: y')       = x == x' && y == y'
  (Aux b meta t) == (Aux b' meta' t') = b == b' && meta == meta' && t == t'
  (Let t _)      == (Let t' _)        = t == t'
  _              == _                 = False

type Grammarly input a meta b =
  (Show a, Show meta, Eq a, Eq meta, Expand input a meta b)

-- | Any metadata-carrying grammar term must be expanded to a stripped-down
-- grammar term with no metadata (i.e. `Term a ()`), possibly producing terms of
-- a different type `b`.
class Expand input a meta b | input a meta -> b where
  -- | Expand meta-information.
  expand :: input -> Term meta a -> IO (Term () b)

  -- default expand :: (Expand input a' meta b, Enum a', Enum a) => input -> Term meta a ->  IO (Term () b)
  -- expand conf = expand conf . fmap ((toEnum :: Int -> a') . fromEnum)

-- | Convert to music (after expansion).
toMusic :: (Expand input a meta b) => input -> Term meta a -> IO (Music b)
toMusic input term = do
  expanded <- expand input term
  go $ unlet expanded
  where go (Prim (a, t)) = return $ Note t a
        go (t :-: t')    = (:+:) <$> toMusic () t <*> toMusic () t'
        go _             = error "toMusic: lets/aux after expansion"

        unlet (Let x k)    = unlet (k x)
        unlet (t :-: t')   = unlet t :-: unlet t'
        unlet (Aux _ () t) = unlet t
        unlet t            = t

-- | A term with no auxiliary wrappers can be trivially expanded.
instance Expand input a () a where
  expand = const return

-- | A term with no auxiliaries can be trivially expanded.
-- instance (Enum a, Enum b, Expand input a meta c) => Expand input b meta c where
--   expand conf = expand conf . fmap ((toEnum :: Int -> b) . fromEnum)

-- | Run a grammar with the given initial symbol.
runGrammar :: Grammarly input a meta b
           => Grammar meta a -> Terminal a -> input -> IO (Music b)
runGrammar grammar initial input = do
  rewritten <- fixpoint (go grammar) (Prim initial)
  toMusic input rewritten
  where
    -- | Run one term of grammar rewriting.
    go :: (Eq meta, Eq a) => Grammar meta a -> Term meta a -> IO (Term meta a)
    -- go _ (Var x) = return $ Var x
    go gram (Let x k) = do
      x' <- go gram x
      return $ Let x' k
    go gram (t :-: t') =
      (:-:) <$> go gram t <*> go gram t'
    go _ a@(Aux True _ _) =
      return a
    go gram (Aux False meta term) =
      Aux False meta <$> go gram term
    go gram (Prim term@(a, t)) = do
      let rules = filter (\((a', _, activ) :-> _) -> a' == a && activ t) gram
      (_ :-> rewrite) <- pickRule term rules
      return $ rewrite t

{- Grammar-specific operators. -}

-- | Rule which always activates.
always :: Activation
always = const True

-- | Conjunction of activation functions.
(/\) :: Activation -> Activation -> Activation
(f /\ g) x = f x && g x

-- | Disjunction of activation functions.
(\/) :: Activation -> Activation -> Activation
(f \/ g) x = f x || g x

-- | Set a primitive term's duration.
(%:) :: a -> Duration -> Term meta a
m %: t = Prim (m, t)

-- | Rule with duration-independent body.
(|->) :: Head a -> Term meta a -> Rule meta a
a |-> b = a :-> const b

-- | Identity rule.
(-|) :: a -> Weight -> Rule meta a
a -| w = (a, w, always) :-> \t -> Prim (a, t)

-- | Identity rule with activation function.
(-||) :: (a, Weight) -> Activation -> Rule meta a
(a, w) -|| f = (a, w, f) :-> \t -> Prim (a, t)

-- | Operators for auxiliary terms.
($:), (|$:) :: meta -> Term meta a -> Term meta a
($:) = Aux False -- auxiliary symbol that allows internal rewriting
(|$:) = Aux True -- frozen auxiliary symbol

{- Helpers. -}

-- | Randomly pick a rule to rewrite given terminal.
pickRule :: Terminal a -> Grammar meta a -> IO (Rule meta a)
pickRule (a, _) [] = return $ a -| 1
pickRule _ rs = do
  let totalWeight = sum ((\((_, w, _) :-> _) -> w) <$> rs)
  index <- getStdRandom $ randomR (0, totalWeight)
  return $ pick' index rs
  where pick' :: Double -> Grammar meta a -> Rule meta a
        pick' n (r@((_, w, _) :-> _):rest) =
          if n <= w then r else pick' (n-w) rest
        pick' _ _ = error "pick: empty list"

-- | Converge to fixpoint with given initial value.
fixpoint :: Eq a => (a -> IO a) -> a -> IO a
fixpoint k l = do
  l' <- k l
  if l == l' then return l else fixpoint k l'
