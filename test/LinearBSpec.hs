{-# OPTIONS_GHC -Wno-orphans #-}
module LinearBSpec where

import Data.Functor
import qualified Data.Map.Strict as M
import Test.Hspec
import LinearB

-- Define some orhpan instances as sugar over non-linear expressions
instance Num Expr where
  (+) = BinOp Add
  (*) = BinOp Mul
  abs = undefined
  signum = undefined
  fromInteger = Lit . fromInteger
  negate = undefined

instance Fractional Expr where
  fromRational = Lit . fromRational
  (/) = undefined

shouldTypeCheck :: Program -> Expectation
shouldTypeCheck prog = do
  let tp = typecheckProgram prog
  case tp of
    (Right ()) -> return ()
    (Left _) -> putStrLn $ show prog
  tp `shouldBe` (Right ())

shouldNotTypeCheck :: Program -> Expectation
shouldNotTypeCheck prog = typecheckProgram prog `shouldSatisfy` \case
  Left  _ -> True
  Right _ -> False

mixedType :: [Type] -> [Type] -> MixedDepType
mixedType ty ty' = MixedDepType (ty <&> \t -> (Nothing, t)) ty'

spec :: Spec
spec = do
  describe "type checker" $ do
    it "accepts an implicit dup" $ do
      shouldTypeCheck $ Program $ M.fromList
        [ ("dup", FuncDef [("x", FloatType)] [] (mixedType [FloatType, FloatType] []) $
            LetDepMixed ["y"] [] (RetDep ["x"] [] (mixedType [FloatType] [])) $
            RetDep ["x", "y"] [] (mixedType [FloatType, FloatType] []))
        ]

    it "checks jvp of case" $ do
      -- jvp (\x. case x of Left f -> f * 2.0; Right () -> 4.0)
      shouldTypeCheck $ Program $ M.fromList
        [ ("case", FuncDef [("x", SumType [FloatType, TupleType []])]
                           [("xt", SumDepType (ProjHere "x") "xb"
                                     [FloatType, TupleType []])]
                           (mixedType [FloatType] [FloatType]) $
            Case "x" "xv"
              [ LetDepMixed ["yv"] []  (BinOp Mul (Var "xv") (Lit 2.0)) $
                LetDepMixed [] ["ytv"] (LScale (Lit 2.0) (LVar "xt")) $
                RetDep ["yv"] ["ytv"]  (mixedType [FloatType] [FloatType])
              , LetDepMixed ["yv"] []  (Lit 4.0) $
                LetDepMixed [] ["ytv"] (LZero) $
                LetDepMixed [] []      (Drop (LVar "xt")) $
                LetDepMixed [] []      (Drop (Var "xv")) $
                RetDep ["yv"] ["ytv"]  (mixedType [FloatType] [FloatType])
              ])
        ]

-- let y = x
-- case y of
--   Left l  -> f l
--   Right r -> g r
--
--
-- \x:(Either ..., Either ...).
--   let (y, z) = x
--   case y of
--     Left l  -> f l
--     Right r -> g r
--
--
-- \x:(Either ..., Either ...).
--   LetUnpack [y, z] (Var x)
--   ...
--
-- \x:(Either ..., Either ...) xt:(SumDepTy x.0 ..., SumDepTy x.1 ...).
--   -- LetDepUnpack [y_tmp, z_tmp] (Var x)
--   -- LetLinUnpack [yt_tmp, zt_tmp] (LVar xt)
--   -- LetDepMixed [y, z] [yt, zt] (RetDep [y_tmp, z_tmp] [yt_tmp, zt_tmp]) !!!!)
--   LetDepUnpack [y, z] [yt, zt] x xt $
--   yt: SumDepTy y ...
--   ...