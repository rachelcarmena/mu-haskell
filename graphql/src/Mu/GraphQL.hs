{-# language DataKinds             #-}
{-# language DeriveFunctor         #-}
{-# language FlexibleContexts      #-}
{-# language FlexibleInstances     #-}
{-# language GADTs                 #-}
{-# language MultiParamTypeClasses #-}
{-# language PolyKinds             #-}
{-# language ScopedTypeVariables   #-}
{-# language TypeApplications      #-}
{-# language TypeFamilies          #-}
{-# language TypeOperators         #-}
{-# language UndecidableInstances  #-}

module Mu.GraphQL where

import           Data.Kind
import           Data.SOP.NP
import           GHC.TypeLits
import           Mu.Schema

-- | Defines whether we should get each field.
--   Invariant: if we have a recursive appearance
--   of the type, 'WantedSubset' must be used.
--   We could fix if with a fixed-point view
--   (using 'Fix'), but it's going too far.
data Wanted a
  = NotWanted
  | WantedValue
  | WantedSubset a
  deriving (Show, Eq, Ord, Functor)

-- | This is the resolver which takes the entire
--   query and returns the entire set of results.
type FullResolver m f
  = f Wanted -> m (f Maybe)

-- COMPOSABLE RESOLVERS
-- ====================
-- We can implement resolvers "piece by piece",
-- and then have a final step which puts
-- everything together.

type SchemaResolver m (sch :: Schema tn fn)
  = NP (TypeResolver m sch) sch

data TypeResolver m (sch :: Schema tn fn) (ty :: TypeDef tn fn) where
  -- | Give the resolver of a record field by field.
  RR :: NP (FieldResolver m sch name) fields
     -> TypeResolver m sch ('DRecord name fields)
  -- | Direct resolver for a record.
  DR :: FullResolver m (W Term sch t)
     -> TypeResolver m sch t
  -- | For types which do not need a resolver.
  --   That is, DEnum and DSimple.
  NR :: TypeResolver m sch t

data FieldResolver m (sch :: Schema tn fn) (ty :: tn) (fld :: FieldDef tn fn) where
  FR :: (Term Maybe sch (sch :/: ty) -> m (ConstructFieldType sch fld))
     -> FieldResolver m sch ty ('FieldDef name fld)

type family ConstructFieldType (sch :: Schema tn fn) (fld :: FieldType tn) :: Type where
  ConstructFieldType sch 'TNull = ()
  ConstructFieldType sch ('TPrimitive p) = p
  ConstructFieldType sch ('TSchematic other) = Term Maybe sch (sch :/: other)
  ConstructFieldType sch ('TOption fld) = Maybe (ConstructFieldType sch fld)
  ConstructFieldType sch ('TList fld) = [ConstructFieldType sch fld]

-- | The composer

newtype W f a b w = W { unW :: f w a b }

-- FOR THE NEXT THING YOU HAVE TWO POSSIBIILITIES

-- Possibility (1)
fullResolverTy
  :: SchemaResolver m sch
  -> FullResolver m (W Term sch ty)
fullResolverTy = undefined

-- Possibility (2), I think this is easier
newtype FullResolver' m sch ty
  = FullResolver' { unFullResolver' :: FullResolver m (W Term sch ty) }

fullResolver
  :: SchemaResolver m sch
  -> NP (FullResolver' m sch) sch
fullResolver = undefined

class FindResolver (sch :: Schema tn fn) (iter :: Schema tn fn) (ty :: TypeDef tn fn) where
  findResolver :: NP (FullResolver' m sch) iter -> FullResolver m (W Term sch ty)

instance TypeError ('Text "cannot find resolver for " ':<>: 'ShowType ty) => FindResolver sch '[] ty where
  findResolver = error "this should never be called"

instance {-# OVERLAPS #-} FindResolver sch (ty ': tys) ty where
  findResolver (r :* _) = unFullResolver' r

instance {-# OVERLAPPABLE #-} FindResolver sch rest ty => FindResolver sch (other ': rest) ty where
  findResolver (_ :* rs) = findResolver rs

fullResolverTy'
  :: (FindResolver sch sch ty)
  => SchemaResolver m sch
  -> FullResolver m (W Term sch ty)
fullResolverTy' = findResolver . fullResolver

-- COMPOSABLE RESOLVERS OVER DOMAIN TYPES
-- ======================================

type SchemaResolverD m (sch :: Schema tn fn)
  = NP (TypeResolverD m sch) sch

data TypeResolverD m (sch :: Schema tn fn) (ty :: TypeDef tn fn) where
  RR_ :: NP (FieldResolverD m sch name) fields
      -> TypeResolverD m sch ('DRecord name fields)
  DR_ :: ( FromSchema Wanted sch ty input
         , ToSchema   Maybe  sch ty output )
      => (input -> m output)
      -> TypeResolverD m sch ('DRecord ty fields)
  OR_ :: TypeResolverD m sch ('DEnum name choice)

data FieldResolverD m (sch :: Schema tn fn) (ty :: tn) (fld :: FieldDef tn fn) where
  FR_ :: ( FromSchema Maybe sch ty input
         , ToSchemaD output (ConstructFieldType sch fld) )
      => (input -> m output)
      -> FieldResolverD m sch ty ('FieldDef name fld)

class ToSchemaD r term where
  toSchemaD :: r -> term

instance {-# OVERLAPPABLE #-} ToSchemaD p p where
  toSchemaD = id

instance {-# OVERLAPS #-} (ToSchema Maybe sch ty r, sch :/: ty ~ t) => ToSchemaD r (Term Maybe sch t) where
  toSchemaD = toSchema @_ @_ @Maybe @sch @ty

instance {-# OVERLAPS #-} (ToSchemaD r term) => ToSchemaD (Maybe r) (Maybe term) where
  toSchemaD = fmap toSchemaD

instance {-# OVERLAPS #-} (ToSchemaD r term) => ToSchemaD [r] [term] where
  toSchemaD = fmap toSchemaD

resolverDomain
  :: SchemaResolverD m sch
  -> SchemaResolver  m sch
resolverDomain = undefined

resolve
  :: forall tn fn (sch :: Schema tn fn) (ty :: tn)
            (m :: Type -> Type) (r :: Type) (s :: Type).
     (Functor m, ToSchema Wanted sch ty r, FromSchema Maybe sch ty s)
  => SchemaResolverD m sch -> r -> m s
resolve r x
  = fromSchema @tn @fn @Maybe @sch @ty . unW <$>
    (fullResolverTy $ resolverDomain r)
    (W $ toSchema @tn @fn @Wanted @sch @ty x)
