{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE DeriveFunctor              #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures             #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE StaticPointers             #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeFamilies               #-}

module Control.Distributed.Dataset.Internal.Dataset where

-------------------------------------------------------------------------------
import           Conduit                                    hiding (Consumer,
                                                             Producer, await)
import qualified Conduit                                    as C
import           Control.Distributed.Closure
import           Control.Distributed.Fork
import           Control.Lens
import           Control.Monad
import           Data.Hashable
import qualified Data.IntMap                                as M
import qualified Data.IntMap.Merge.Strict                   as M
import           Data.IORef
import           Data.List                                  (foldl', sortBy,
                                                             transpose)
import           Data.List.Split
import           Data.Ord
import           Data.Typeable
import           System.Random
-------------------------------------------------------------------------------
import           Control.Distributed.Dataset.Internal.Class
import           Control.Distributed.Dataset.ShuffleStore
import           Data.Conduit.Serialise
-------------------------------------------------------------------------------

-- * Partition

-- |
-- Represents some amount of data which to be transformed on a single
-- executor.
data Partition a
  = PSimple (Closure (ConduitT () a (ResourceT IO) ()))
  | PCombined [Partition a]

instance Semigroup (Partition a) where
  PCombined a <> PCombined b = PCombined (a ++ b)
  PCombined a <> b = PCombined (b:a)
  a <> PCombined b = PCombined (a:b)
  a <> b = PCombined [a, b]

instance Monoid (Partition a) where
  mempty = PCombined []

-- |
-- Streams the elements from a 'Partition'.
partitionProducer :: Typeable a => Partition a -> Closure (ConduitT () a (ResourceT IO) ())
partitionProducer (PSimple p) = p
partitionProducer (PCombined ps) =
  let cps = foldr
              (\cp cl -> static (\p l -> p:l) `cap` cp `cap` cl)
              (static [])
              (map partitionProducer ps)
  in  static sequence_ `cap` cps

-- * Dataset

-- |
-- Represents a set of transformations that results in a set of 'a's.
--
-- Dataset's are partitioned and transformed by in a distributed fashion.
--
-- Operations on 'Dataset's will only be performed when the result is requested.
data Dataset a where
  DExternal  :: [Partition a] -> Dataset a
  DPipe      :: (StaticSerialise a, StaticSerialise b)
             => Closure (ConduitT a b (ResourceT IO) ())
             -> Dataset a -> Dataset b
  DPartition :: (StaticHashable k, StaticSerialise a)
             => Int
             -> Closure (a -> k)
             -> Dataset a -> Dataset a
  DCoalesce  :: Int -> Dataset a -> Dataset a

-- * Stage

data Stage a where
  SInit :: [Partition a] -> Stage a
  SNarrow :: (StaticSerialise a, StaticSerialise b)
          => Closure (ConduitM a b (ResourceT IO) ()) -> Stage a -> Stage b
  SWide :: (StaticSerialise a, StaticSerialise b)
        => Int -> Closure (ConduitM a (Int, b) (ResourceT IO) ()) -> Stage a -> Stage b
  SCoalesce :: Int -> Stage a -> Stage a

mkStages :: Dataset a -> Stage a
mkStages (DExternal a) = SInit a
mkStages (DPipe p rest) =
  case mkStages rest of
    SNarrow prev r ->
      SNarrow (static (\prev' p' -> prev' .| p') `cap` prev `cap` p) r
    other ->
      SNarrow p other
mkStages (DPartition count (cf :: Closure (a -> k)) rest) =
  case mkStages rest of
    SNarrow cp rest' ->
      SWide count
            (static (\Dict p f -> p .| partition @a @k f)
               `cap` staticHashable @k
               `cap` cp
               `cap` cf)
            rest'
    other ->
      SWide count
            (static (\Dict -> partition @a @k)
              `cap` staticHashable @k
              `cap` cf
            )
            other
  where
    partition :: forall t e m. (Hashable e, Monad m) => (t -> e) -> ConduitT t (Int, t) m ()
    partition f =
      C.await >>= \case
        Nothing -> return ()
        Just a  -> C.yield (hash (f a), a) >> partition f
mkStages (DCoalesce count rest) =
  case mkStages rest of
    SNarrow cp rest' ->
      SNarrow cp (SCoalesce count rest')
    SCoalesce _ rest' ->
      SCoalesce count rest'
    other ->
      SCoalesce count other


runStages :: forall a. Stage a -> DD [Partition a]
runStages (SInit ps) = do
  return ps

runStages (SNarrow cpipe rest) = do
  inputs <- runStages rest
  shuffleStore <- view ddShuffleStore
  tasks <- forM inputs $ \input -> do
    num <- liftIO randomIO
    let coutput = ssPut shuffleStore `cap` cpure (static Dict) num
        cinput = ssGet shuffleStore `cap` cpure (static Dict) num `cap` cpure (static Dict) RangeAll
        crun = static (\Dict producer pipe output ->
                          C.runConduitRes
                            $ producer
                                .| pipe
                                .| serialiseC @a
                                .| output
                 ) `cap` staticSerialise @a `cap` partitionProducer input `cap` cpipe `cap` coutput
        newPartition = PSimple @a (static (\Dict input' -> input' .| deserialiseC)
                           `cap` staticSerialise @a `cap` cinput)
    return (crun, newPartition)
  backend <- view ddBackend
  handles <- mapM (liftIO . fork backend (static Dict) . fst) tasks
  mapM_ await handles
  return $ map snd tasks

runStages (SWide count cpipe rest) = do
  inputs <- runStages rest
  shuffleStore <- view ddShuffleStore
  tasks <- forM inputs $ \partition -> do
    num <- liftIO $ randomIO
    let coutput = ssPut shuffleStore `cap` cpure (static Dict) num
        crun = static (\Dict count' input pipe output -> do
          ref <- newIORef @[(Int, (Integer, Integer))] []
          C.runConduitRes $
            input
                .| pipe
                .| mapC (\(k, v) -> (k `mod` count', v))
                .| sort @(ResourceT IO)
                .| (serialiseWithLocC @a @Int @(ResourceT IO) >>= liftIO . writeIORef ref)
                .| output
          readIORef ref
          ) `cap` staticSerialise @a
            `cap` cpure (static Dict) count
            `cap` partitionProducer partition
            `cap` cpipe
            `cap` coutput
    backend <- view ddBackend
    handle <- fork backend (static Dict) crun
    return (handle, num)
  partitions <- forM tasks $ \(handle, num) -> do
    res <- await handle
    forM res $ \(partition, (start, end)) ->
      return ( partition
             , PSimple @a (static (\Dict input' -> input' .| deserialiseC)
                           `cap` staticSerialise @a
                           `cap` (ssGet shuffleStore
                                    `cap` cpure (static Dict) num
                                    `cap` cpure (static Dict) (RangeOnly start end)
                                 )
                          )
             )

  map M.fromList partitions
    & foldl' (M.merge M.preserveMissing M.preserveMissing (M.zipWithMatched $ const mappend)) M.empty
    & M.toList
    & map snd
    & return

  where
    sort :: Monad m => ConduitT (Int, t) (Int, t) m ()
    sort = mapM_ yield . sortBy (comparing fst) =<< C.sinkList

runStages (SCoalesce count rest) = do
  inputs <- runStages rest
  return $ map mconcat $ transpose (chunksOf count inputs)

-- * Dataset API


-- |
-- Streams the complete Dataset.
dFetch :: StaticSerialise a
       => Dataset a
       -> DD (ConduitT () a (ResourceT IO) ())
dFetch ds = do
  out <- runStages $ mkStages ds
  return $ mapM_ (unclosure . partitionProducer) out

-- |
-- Fetches the complete dataset as a list.
dToList :: StaticSerialise a
        => Dataset a
        -> DD [a]
dToList ds = do
  c <- dFetch ds
  liftIO $ runConduitRes $ c .| sinkList
