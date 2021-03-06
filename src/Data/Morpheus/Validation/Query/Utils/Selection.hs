{-# LANGUAGE NamedFieldPuns #-}

module Data.Morpheus.Validation.Query.Utils.Selection
  ( lookupFieldAsSelectionSet
  , lookupSelectionField
  , lookupUnionTypes
  ) where

import           Data.Morpheus.Error.Selection           (cannotQueryField, hasNoSubfields)
import           Data.Morpheus.Types.Internal.Base       (Position)
import           Data.Morpheus.Types.Internal.Data       (DataField (..), DataObject, DataTyCon (..), DataTypeLib (..),
                                                          TypeAlias (..))
import           Data.Morpheus.Types.Internal.Validation (Validation)
import           Data.Morpheus.Validation.Internal.Utils (lookupField, lookupType)
import           Data.Text                               (Text)

lookupUnionTypes :: Position -> Text -> DataTypeLib -> DataField -> Validation [DataObject]
lookupUnionTypes position' key' lib DataField {fieldType = TypeAlias {aliasTyCon = type'}} =
  lookupType error' (union lib) type' >>= mapM (lookupType error' (object lib) . aliasTyCon . fieldType) . typeData
  where
    error' = hasNoSubfields key' type' position'

lookupFieldAsSelectionSet :: Position -> Text -> DataTypeLib -> DataField -> Validation DataObject
lookupFieldAsSelectionSet position key' lib DataField {fieldType = TypeAlias {aliasTyCon = type'}} =
  lookupType error' (object lib) type'
  where
    error' = hasNoSubfields key' type' position

lookupSelectionField :: Position -> Text -> DataObject -> Validation DataField
lookupSelectionField position' key' DataTyCon {typeData = fields', typeName = name'} = lookupField key' fields' error'
  where
    error' = cannotQueryField key' name' position'
