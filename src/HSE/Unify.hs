{-# LANGUAGE PatternGuards, ViewPatterns, FlexibleContexts, ScopedTypeVariables #-}

module HSE.Unify(
    Subst, fromSubst,
    unifyExp, check,
    substitute, substT,
    ) where

import Control.Applicative
import Data.List.Extra
import Data.Maybe
import Data.Data
import Data.Monoid
import Config.Type
import Hint.Type
import Control.Monad
import Data.Tuple.Extra
import Util
import Prelude


---------------------------------------------------------------------
-- SUBSTITUTION DATA TYPE

-- | A list of substitutions. A key may be duplicated, you need to call 'check'
--   to ensure the substitution is valid.
newtype Subst a = Subst [(String, a)]

-- | Unpack the substitution
fromSubst :: Subst a -> [(String, a)]
fromSubst (Subst xs) = xs

instance Functor Subst where
    fmap f (Subst xs) = Subst $ map (second f) xs

instance Pretty a => Show (Subst a) where
    show (Subst xs) = unlines [a ++ " = " ++ prettyPrint b | (a,b) <- xs]

instance Monoid (Subst a) where
    mempty = Subst []
    mappend (Subst xs) (Subst ys) = Subst $ xs ++ ys


-- check the unification is valid and simplify it
check :: Subst Exp_ -> Maybe (Subst Exp_)
check = fmap Subst . mapM f . groupSort . fromSubst
    where f (x,ys) = if checkSame ys then Just (x,head ys) else Nothing
          checkSame [] = True
          checkSame (x:xs) = all (x =~=) xs


---------------------------------------------------------------------
-- UNIFICATION

type NameMatch = QName S -> QName S -> Bool

nmOp :: NameMatch -> QOp S -> QOp S -> Bool
nmOp nm (QVarOp _ x) (QVarOp _ y) = nm x y
nmOp nm (QConOp _ x) (QConOp _ y) = nm x y
nmOp nm  _ _ = False


-- unify a b = c, a[c] = b
unify :: Data a => NameMatch -> Bool -> a -> a -> Maybe (Subst Exp_)
unify nm root x y | Just (x,y) <- cast (x,y) = unifyExp nm root x y
                  | Just (x,y) <- cast (x,y) = unifyPat nm x y
                  | Just (x :: S) <- cast x = Just mempty
                  | otherwise = unifyDef nm x y


unifyDef :: Data a => NameMatch -> a -> a -> Maybe (Subst Exp_)
unifyDef nm x y = fmap mconcat . sequence =<< gzip (unify nm False) x y


-- App/InfixApp are analysed specially for performance reasons
-- root = True, this is the outside of the expr
-- do not expand out a dot at the root, since otherwise you get two matches because of readRule (Bug #570)
unifyExp :: NameMatch -> Bool -> Exp_ -> Exp_ -> Maybe (Subst Exp_)
unifyExp nm root x y | isParen x || isParen y =
  Subst . map (rebracket y) . fromSubst <$> unifyExp nm root (fromParen x) (fromParen y)
unifyExp nm root (Var _ (fromNamed -> v)) y | isUnifyVar v = Just $ Subst [(v,y)]
unifyExp nm root (Var _ x) (Var _ y) | nm x y = Just mempty

-- Hand unrolled for performance
unifyExp nm root x@(App _ x1 x2) (App _ y1 y2) =
    liftM2 (<>) (unifyExp nm False x1 y1) (unifyExp nm False x2 y2) `mplus`
    (do guard $ not root; InfixApp _ y11 dot y12 <- return $ fromParen y1; guard $ isDot dot; unifyExp nm root x (App an y11 (App an y12 y2)))
unifyExp nm root x (InfixApp _ lhs2 op2 rhs2)
    | InfixApp _ lhs1 op1 rhs1 <- x = guard (nmOp nm op1 op2) >> liftM2 (<>) (unifyExp nm False lhs1 lhs2) (unifyExp nm False rhs1 rhs2)
    | isDol op2 = unifyExp nm root x $ App an lhs2 rhs2
    | otherwise = unifyExp nm root x $ App an (App an (opExp op2) lhs2) rhs2

unifyExp nm root x y | isOther x, isOther y = unifyDef nm x y
unifyExp nm root _ _ = Nothing

rebracket (Paren l e') (v, e)
  | e' == e = (v, Paren l e)
rebracket e (v, e') = (v, e')


unifyPat :: NameMatch -> Pat_ -> Pat_ -> Maybe (Subst Exp_)
unifyPat nm (PVar _ x) (PVar _ y) = Just $ Subst [(fromNamed x, toNamed $ fromNamed y)]
unifyPat nm (PVar _ x) PWildCard{} = Just $ Subst [(fromNamed x, toNamed $ "_" ++ fromNamed x)]
unifyPat nm x y = unifyDef nm x y


-- types that are not already handled in unify
{-# INLINE isOther #-}
isOther Var{} = False
isOther App{} = False
isOther InfixApp{} = False
isOther _ = True


---------------------------------------------------------------------
-- SUBSTITUTION UTILITIES

-- perform a substitution
substitute :: Subst Exp_ -> Exp_ -> Exp_
substitute (Subst bind) = transform g . transformBracket f
    where
        f (Var _ (fromNamed -> x)) | isUnifyVar x = lookup x bind
        f _ = Nothing

        g (App _ np x) | np ~= "_noParen_" = fromParen x
        g x = x


-- | Descend, and if something changes then add/remove brackets appropriately in both the template
-- and the original expression.
descendBracketTemplate :: (Exp_ -> (Bool, (Exp_, Exp_))) -> Exp_ -> Exp_
descendBracketTemplate op x = descendIndex g x
    where
        g i y = if a then f i b else fst b
            where (a, b) = op y

        f i (v, y) | needBracket i x y = addParen v
        f i (v, y) = v

transformBracketTemplate :: (Exp_ -> Maybe (Exp_, Exp_)) -> Exp_ -> Exp_
transformBracketTemplate op = fst . snd . g
    where
        g :: Exp_ -> (Bool, (Exp_, Exp_))
        g = f . descendBracketTemplate g
        f :: Exp_ -> (Bool, (Exp_, Exp_))
        f x = maybe (False,(x, x)) ((,) True) (op x)

-- perform a substitution
substT :: Subst Exp_ -> Exp_ -> Exp_
substT (Subst bind) = transform g . transformBracketTemplate f
    where
        f v@(Var _ (fromNamed -> x)) | isUnifyVar x = case lookup x bind of
                                                        Just x -> if ann x == an then  Just (x, x)
                                                                                 else  Just (v, x)
                                                        Nothing -> Nothing
        f _ = Nothing

        g (App _ np x) | np ~= "_noParen_" = fromParen x
        g x = x
