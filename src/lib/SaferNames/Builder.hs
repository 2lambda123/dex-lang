-- Copyright 2021 Google LLC
--
-- Use of this source code is governed by a BSD-style
-- license that can be found in the LICENSE file or at
-- https://developers.google.com/open-source/licenses/bsd

{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE TypeFamilies #-}

module SaferNames.Builder (
  emit, emitOp, buildLamGeneral,
  buildPureLam, BuilderT, Builder (..), Builder2,
  runBuilderT, buildBlock, app, add, mul, sub, neg, div',
  iadd, imul, isub, idiv, ilt, ieq, irem,
  fpow, flog, fLitLike, recGetHead, buildPureNaryLam,
  makeSuperclassGetter, makeMethodGetter,
  select, getUnpacked,
  fromPair, getFst, getSnd, getProj, getProjRef, naryApp,
  getDataDef, getClassDef, liftBuilderNameGenT, atomAsBlock,
  Emits, buildPi, buildNonDepPi, buildLam, buildDepEffLam,
  buildAbs, buildNaryAbs, buildNewtype
  ) where

import Prelude hiding ((.), id)
import Control.Category
import Control.Monad
import Data.Foldable (toList)
import Data.List (elemIndex)
import Data.Maybe (fromJust)

import Unsafe.Coerce

import SaferNames.NameCore
import SaferNames.Name
import SaferNames.Syntax
import SaferNames.Type
import SaferNames.PPrint ()

import Err
import LabeledItems

class (BindingsReader m, Scopable m, MonadFail1 m)
      => Builder (m::MonadKind1) where
  emitDecl :: Emits n => NameHint -> LetAnn -> Expr n -> m n (AtomName n)
  buildScoped :: (InjectableE e, HasNamesE e)
              => (forall l. (Emits l, Ext n l) => m l (e l))
              -> m n (Abs (Nest Decl) e n)
  getAllowedEffects :: m n (EffectRow n)
  withAllowedEffects :: EffectRow n -> m n a -> m n a

type Builder2       (m :: MonadKind2) = forall i. Builder (m i)

emit :: (Builder m, Emits n) => Expr n -> m n (AtomName n)
emit expr = emitDecl NoHint PlainLet expr

emitOp :: (Builder m, Emits n) => Op n -> m n (Atom n)
emitOp op = Var <$> emit (Op op)

-- === BuilderNameGenT ===

newtype BuilderNameGenT (decl::B) (m::MonadKind1) (e::E) (n::S) =
  BuilderNameGenT { runBuilderNameGenT :: m n (DistinctAbs (Nest decl) e n) }

instance (BindingsReader m, BindingsExtender m, Monad1 m, BindsBindings decl)
         => NameGen (BuilderNameGenT decl m) where
  returnG e = BuilderNameGenT $ do
    Distinct <- getDistinct
    return (DistinctAbs Empty e)
  bindG (BuilderNameGenT m) f = BuilderNameGenT do
    DistinctAbs decls  e  <- m
    DistinctAbs decls' e' <- extendBindings (boundBindings decls) $ runBuilderNameGenT $ f e
    return $ DistinctAbs (decls >>> decls') e'
  getDistinctEvidenceG = BuilderNameGenT do
    Distinct <- getDistinct
    return $ DistinctAbs Empty getDistinctEvidence

liftBuilderNameGenT :: ScopeReader m => m n (e n) -> BuilderNameGenT decl m e n
liftBuilderNameGenT m = BuilderNameGenT do
  Distinct <- getDistinct
  result <- m
  return $ DistinctAbs Empty result

-- === BuilderT ===

newtype BuilderT (m::MonadKind1) (n::S) (a:: *) =
  BuilderT { runBuilderT' :: Inplace (BuilderNameGenT Decl m) n a }
  deriving (Functor, Applicative, Monad)

runBuilderT
  :: ( BindingsReader m, BindingsGetter m, BindingsExtender m, MonadFail1 m
     , InjectableE e, HasNamesE e)
  => (forall l. (Distinct l, Ext n l) => BuilderT m l (e l))
  -> m n (e n)
runBuilderT cont = do
  DistinctAbs decls result <- runBuilderNameGenT $ runInplace $ runBuilderT' cont
  -- this should always succeed because we don't supply the `Emits` predicate to
  -- the continuation
  fromConstAbs $ Abs decls result

runBuilderTWithEmits
  :: ( BindingsReader m, BindingsGetter m, BindingsExtender m, MonadFail1 m
     , InjectableE e, HasNamesE e)
  => (forall l. (Emits l, Distinct l, Ext n l) => BuilderT m l (e l))
  -> m n (Abs (Nest Decl) e n)
runBuilderTWithEmits cont = do
  DistinctAbs decls result <- runBuilderNameGenT $ runInplace $ runBuilderT' do
    evidence <- fabricateEmitsEvidenceM
    withEmitsEvidence evidence do
      cont
  return $ Abs decls result

-- TODO: should be able to get away with `Scopable m` instead of `BindingsExtender m`
instance (BindingsReader m, BindingsGetter m, BindingsExtender m, MonadFail1 m)
         => Builder (BuilderT m) where
  emitDecl hint ann expr = BuilderT $
    liftInplace $ BuilderNameGenT do
      expr' <- injectM expr
      ty <- getType expr'
      let binderInfo = LetBound ann expr'
      withFreshBinder hint ty binderInfo \b -> do
        return $ DistinctAbs (Nest (Let ann b expr') Empty) (binderName b)

  buildScoped cont = do
    ext1 <- idExt
    BuilderT $ liftInplace $ BuilderNameGenT do
      ext2 <- injectExt ext1
      result <- runBuilderTWithEmits do
                  ExtW <- injectExt ext2
                  cont
      Distinct <- getDistinct
      return $ DistinctAbs id result

  getAllowedEffects = undefined
  withAllowedEffects _ _ = undefined

instance (BindingsReader m, BindingsGetter m, BindingsExtender m, MonadFail1 m)
         => MonadFail (BuilderT m n) where
  fail = undefined

instance (BindingsReader m, BindingsGetter m, BindingsExtender m, MonadFail1 m)
         => ScopeReader (BuilderT m) where
  getDistinctEvidenceM = BuilderT $
    liftInplace $ liftBuilderNameGenT getDistinctEvidenceM
  addScope e = BuilderT $
    liftInplace $
      liftBuilderNameGenT do
        e' <- injectM e
        addScope e'

instance (BindingsReader m, BindingsGetter m, BindingsExtender m, MonadFail1 m)
         => BindingsReader (BuilderT m) where
  addBindings e = BuilderT $
    liftInplace $
      liftBuilderNameGenT do
        e' <- injectM e
        addBindings e'

instance (BindingsReader m, BindingsGetter m, BindingsExtender m, MonadFail1 m)
         => Scopable (BuilderT m) where
  withBindings  _ _ = undefined

-- === Emits predicate ===

-- We use the `Emits` predicate on scope parameters to indicate that we may emit
-- decls. This lets us ensure that a computation *doesn't* emit decls, by
-- supplying a fresh name without supplying the `Emits` predicate.

data EmitsEvidence (n::S) = FabricateEmitsEvidence

class Emits (n::S)

instance Emits UnsafeS

withEmitsEvidence :: forall n a. EmitsEvidence n -> (Emits n => a) -> a
withEmitsEvidence _ cont = fromWrapWithEmits
 ( unsafeCoerce ( WrapWithEmits cont :: WrapWithEmits n       a
                                   ) :: WrapWithEmits UnsafeS a)

newtype WrapWithEmits n r =
  WrapWithEmits { fromWrapWithEmits :: Emits n => r }

fabricateEmitsEvidenceM :: Monad1 m => m n (EmitsEvidence n)
fabricateEmitsEvidenceM = return FabricateEmitsEvidence

-- === lambda-like things ===

buildBlockAux :: Builder m
           => (forall l. (Emits l, Ext n l) => m l (Atom l, a))
           -> m n (Block n, a)
buildBlockAux cont = do
  Abs decls (result `PairE` ty `PairE` LiftE aux) <- buildScoped do
    (result, aux) <- cont
    ty <- getType result
    return $ result `PairE` ty `PairE` LiftE aux
  ty' <- fromConstAbs $ Abs decls ty
  return (Block ty' decls $ Atom result, aux)

buildBlock :: Builder m
           => (forall l. (Emits l, Ext n l) => m l (Atom l))
           -> m n (Block n)
buildBlock cont = fst <$> buildBlockAux do
  result <- cont
  return (result, ())

atomAsBlock :: BindingsReader m => Atom n -> m n (Block n)
atomAsBlock x = do
  ty <- getType x
  return $ Block ty Empty $ Atom x

data BinderWithInfo n l =
  BinderWithInfo (Binder n l) (AtomBinderInfo n)

instance GenericB BinderWithInfo where
  type RepB BinderWithInfo = BinderP Binder AtomBinderInfo
  fromB (BinderWithInfo b info) = b:>info
  toB   (b:>info) = BinderWithInfo b info

instance ProvesExt   BinderWithInfo
instance BindsNames  BinderWithInfo
instance InjectableB BinderWithInfo
instance SubstB Name BinderWithInfo
instance BindsBindings BinderWithInfo where
  boundBindings (BinderWithInfo (b:>ty) info) =
    withExtEvidence b $
      b @> inject (AtomNameBinding ty info)

withFreshAtomBinder :: (Scopable m, SubstE Name e, InjectableE e)
                    => NameHint -> Type n -> AtomBinderInfo n
                    -> (forall l. Ext n l => AtomName l -> m l (e l))
                    -> m n (Abs Binder e n)
withFreshAtomBinder hint ty info cont = do
  Abs b name <- freshBinderNamePair hint
  Abs (BinderWithInfo b' _) body <-
    withBindings (Abs (BinderWithInfo (b:>ty) info) name) cont
  return $ Abs b' body

buildLamGeneral
  :: Builder m
  => Arrow
  -> Type n
  -> (forall l. (         Ext n l) => AtomName l -> m l (EffectRow l))
  -> (forall l. (Emits l, Ext n l) => AtomName l -> m l (Atom l, a))
  -> m n (Atom n, a)
buildLamGeneral arr ty fEff fBody = do
  ext1 <- idExt
  ab <- withFreshAtomBinder NoHint ty (LamBound arr) \v -> do
    ext2 <- injectExt ext1
    effs <- fEff v
    withAllowedEffects effs do
      (body, aux) <- buildBlockAux do
        ExtW <- injectExt ext2
        v' <- injectM v
        fBody v'
      return $ effs `PairE` body `PairE` LiftE aux
  Abs b (effs `PairE` body `PairE` LiftE aux) <- return ab
  return (Lam $ LamExpr arr b effs body, aux)

buildPureLam :: Builder m
             => Arrow
             -> Type n
             -> (forall l. (Emits l, Ext n l) => AtomName l -> m l (Atom l))
             -> m n (Atom n)
buildPureLam arr ty body =
  fst <$> buildLamGeneral arr ty (const $ return Pure) \x ->
    withAllowedEffects Pure do
      result <- body x
      return (result, ())

buildLam
  :: Builder m
  => Arrow
  -> Type n
  -> EffectRow n
  -> (forall l. (Emits l, Ext n l) => AtomName l -> m l (Atom l))
  -> m n (Atom n)
buildLam arr ty effBuilder body = undefined

buildDepEffLam
  :: Builder m
  => Arrow
  -> Type n
  -> (forall l. (         Ext n l) => AtomName l -> m l (EffectRow l))
  -> (forall l. (Emits l, Ext n l) => AtomName l -> m l (Atom l))
  -> m n (Atom n)
buildDepEffLam arr ty effBuilder body = undefined

-- Body must be an Atom because otherwise the nullary case would require
-- emitting decls into the enclosing scope.
buildPureNaryLam :: Builder m
                 => Arrow
                 -> EmptyAbs (Nest Binder) n
                 -> (forall l. Ext n l => [AtomName l] -> m l (Atom l))
                 -> m n (Atom n)
buildPureNaryLam _ (EmptyAbs Empty) cont = cont []
buildPureNaryLam arr (EmptyAbs (Nest (b:>ty) rest)) cont = do
  ext1 <- idExt
  buildPureLam arr ty \x -> do
    ext2 <- injectExt ext1
    restAbs <- injectM $ Abs b $ EmptyAbs rest
    rest' <- applyAbs restAbs x
    buildPureNaryLam arr rest' \xs -> do
      ExtW <- injectExt ext2
      x' <- injectM x
      cont (x':xs)
buildPureNaryLam _ _ _ = error "impossible"

buildPi :: (MonadErr1 m, Builder m)
        => Type n
        -> (forall l. Ext n l => AtomName l -> m l (EffectRow l, Type l))
        -> m n (Type n)
buildPi _ _ = undefined

buildNonDepPi :: (MonadErr1 m, Builder m)
              => Type n -> EffectRow n -> Type n -> m n (Type n)
buildNonDepPi = undefined

buildAbs
  :: (Builder m, InjectableE e, HasNamesE e)
  => Type n
  -> (forall l. Ext n l => AtomName l -> m l (e l))
  -> m n (Abs Binder e n)
buildAbs ty body = do
  withFreshAtomBinder NoHint ty MiscBound \v -> do
    body v

buildNaryAbs
  :: (Builder m, InjectableE e, HasNamesE e)
  => EmptyAbs (Nest Binder) n
  -> (forall l. Ext n l => [AtomName l] -> m l (e l))
  -> m n (Abs (Nest Binder) e n)
buildNaryAbs ty body = undefined

buildNewtype :: Builder m
             => SourceName
             -> EmptyAbs (Nest Binder) n
             -> (forall l. Ext n l => [AtomName l] -> m l (Type l))
             -> m n (DataDef n)
buildNewtype _ _ _ = undefined

-- === builder versions of common ops ===

getDataDef :: Builder m => DataDefName n -> m n (DataDef n)
getDataDef _ = undefined

getClassDef :: BindingsReader m => Name ClassNameC n -> m n (ClassDef n)
getClassDef classDefName = do
  ~(ClassBinding classDef) <- lookupBindings classDefName
  return classDef

makeMethodGetter :: Builder m => Name ClassNameC n -> Int -> m n (Atom n)
makeMethodGetter classDefName methodIdx = do
  ClassDef _ _ (defName, def@(DataDef _ paramBs _)) <- getClassDef classDefName
  buildPureNaryLam ImplicitArrow (EmptyAbs paramBs) \params -> do
    defName' <- injectM defName
    def'     <- injectM def
    buildPureLam ClassArrow (TypeCon (defName', def') (map Var params)) \dict ->
      return $ getProjection [methodIdx] $ getProjection [1, 0] $ Var dict

makeSuperclassGetter :: Builder m => Name ClassNameC n -> Int -> m n (Atom n)
makeSuperclassGetter classDefName methodIdx = do
  ClassDef _ _ (defName, def@(DataDef _ paramBs _)) <- getClassDef classDefName
  buildPureNaryLam ImplicitArrow (EmptyAbs paramBs) \params -> do
    defName' <- injectM defName
    def'     <- injectM def
    buildPureLam PlainArrow (TypeCon (defName', def') (map Var params)) \dict ->
      return $ getProjection [methodIdx] $ getProjection [0, 0] $ Var dict

recGetHead :: BindingsReader m => Label -> Atom n -> m n (Atom n)
recGetHead l x = do
  ~(RecordTy (Ext r _)) <- getType x
  let i = fromJust $ elemIndex l $ map fst $ toList $ reflectLabels r
  return $ getProjection [i] x

fLitLike :: (Builder m, Emits n) => Double -> Atom n -> m n (Atom n)
fLitLike x t = do
  ty <- getType t
  case ty of
    BaseTy (Scalar Float64Type) -> return $ Con $ Lit $ Float64Lit x
    BaseTy (Scalar Float32Type) -> return $ Con $ Lit $ Float32Lit $ realToFrac x
    _ -> error "Expected a floating point scalar"

neg :: (Builder m, Emits n) => Atom n -> m n (Atom n)
neg x = emitOp $ ScalarUnOp FNeg x

add :: (Builder m, Emits n) => Atom n -> Atom n -> m n (Atom n)
add x y = emitOp $ ScalarBinOp FAdd x y

-- TODO: Implement constant folding for fixed-width integer types as well!
iadd :: (Builder m, Emits n) => Atom n -> Atom n -> m n (Atom n)
iadd (Con (Lit l)) y | getIntLit l == 0 = return y
iadd x (Con (Lit l)) | getIntLit l == 0 = return x
iadd x@(Con (Lit _)) y@(Con (Lit _)) = return $ applyIntBinOp (+) x y
iadd x y = emitOp $ ScalarBinOp IAdd x y

mul :: (Builder m, Emits n) => Atom n -> Atom n -> m n (Atom n)
mul x y = emitOp $ ScalarBinOp FMul x y

imul :: (Builder m, Emits n) => Atom n -> Atom n -> m n (Atom n)
imul   (Con (Lit l)) y               | getIntLit l == 1 = return y
imul x                 (Con (Lit l)) | getIntLit l == 1 = return x
imul x@(Con (Lit _)) y@(Con (Lit _))                    = return $ applyIntBinOp (*) x y
imul x y = emitOp $ ScalarBinOp IMul x y

sub :: (Builder m, Emits n) => Atom n -> Atom n -> m n (Atom n)
sub x y = emitOp $ ScalarBinOp FSub x y

isub :: (Builder m, Emits n) => Atom n -> Atom n -> m n (Atom n)
isub x (Con (Lit l)) | getIntLit l == 0 = return x
isub x@(Con (Lit _)) y@(Con (Lit _)) = return $ applyIntBinOp (-) x y
isub x y = emitOp $ ScalarBinOp ISub x y

select :: (Builder m, Emits n) => Atom n -> Atom n -> Atom n -> m n (Atom n)
select (Con (Lit (Word8Lit p))) x y = return $ if p /= 0 then x else y
select p x y = emitOp $ Select p x y

div' :: (Builder m, Emits n) => Atom n -> Atom n -> m n (Atom n)
div' x y = emitOp $ ScalarBinOp FDiv x y

idiv :: (Builder m, Emits n) => Atom n -> Atom n -> m n (Atom n)
idiv x (Con (Lit l)) | getIntLit l == 1 = return x
idiv x@(Con (Lit _)) y@(Con (Lit _)) = return $ applyIntBinOp div x y
idiv x y = emitOp $ ScalarBinOp IDiv x y

irem :: (Builder m, Emits n) => Atom n -> Atom n -> m n (Atom n)
irem x y = emitOp $ ScalarBinOp IRem x y

fpow :: (Builder m, Emits n) => Atom n -> Atom n -> m n (Atom n)
fpow x y = emitOp $ ScalarBinOp FPow x y

flog :: (Builder m, Emits n) => Atom n -> m n (Atom n)
flog x = emitOp $ ScalarUnOp Log x

ilt :: (Builder m, Emits n) => Atom n -> Atom n -> m n (Atom n)
ilt x@(Con (Lit _)) y@(Con (Lit _)) = return $ applyIntCmpOp (<) x y
ilt x y = emitOp $ ScalarBinOp (ICmp Less) x y

ieq :: (Builder m, Emits n) => Atom n -> Atom n -> m n (Atom n)
ieq x@(Con (Lit _)) y@(Con (Lit _)) = return $ applyIntCmpOp (==) x y
ieq x y = emitOp $ ScalarBinOp (ICmp Equal) x y

fromPair :: (Builder m, Emits n) => Atom n -> m n (Atom n, Atom n)
fromPair pair = do
  ~[x, y] <- getUnpacked pair
  return (x, y)

getProj :: (Builder m, Emits n) => Int -> Atom n -> m n (Atom n)
getProj i x = do
  xs <- getUnpacked x
  return $ xs !! i

getFst :: (Builder m, Emits n) => Atom n -> m n (Atom n)
getFst p = fst <$> fromPair p

getSnd :: (Builder m, Emits n) => Atom n -> m n (Atom n)
getSnd p = snd <$> fromPair p

getProjRef :: (Builder m, Emits n) => Int -> Atom n -> m n (Atom n)
getProjRef i r = emitOp $ ProjRef i r

-- XXX: getUnpacked must reduce its argument to enforce the invariant that
-- ProjectElt atoms are always fully reduced (to avoid type errors between two
-- equivalent types spelled differently).
getUnpacked :: (Builder m, Emits n) => Atom n -> m n [Atom n]
getUnpacked = undefined
-- getUnpacked (ProdVal xs) = return xs
-- getUnpacked atom = do
--   scope <- getScope
--   let len = projectLength $ getType atom
--       atom' = typeReduceAtom scope atom
--       res = map (\i -> getProjection [i] atom') [0..(len-1)]
--   return res

app :: (Builder m, Emits n) => Atom n -> Atom n -> m n (Atom n)
app x i = Var <$> emit (App x i)

naryApp :: (Builder m, Emits n) => Atom n -> [Atom n] -> m n (Atom n)
naryApp f xs = foldM app f xs
