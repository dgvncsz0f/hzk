{-# LANGUAGE OverloadedStrings #-}

-- This file is part of zhk
--
-- All rights reserved.
--  
-- Redistribution and use in source and binary forms, with or without modification,
-- are permitted provided that the following conditions are met:
--  
--   Redistributions of source code must retain the above copyright notice, this
--   list of conditions and the following disclaimer.
--  
--   Redistributions in binary form must reproduce the above copyright notice, this
--   list of conditions and the following disclaimer in the documentation and/or
--   other materials provided with the distribution.
--  
--   Neither the name of the {organization} nor the names of its
--   contributors may be used to endorse or promote products derived from
--   this software without specific prior written permission.
--  
-- THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
-- ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
-- WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
-- DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
-- ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
-- (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
-- LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
-- ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
-- (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
-- SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

module Main where

import Data.Maybe
import Test.Tasty
import System.Exit
import Control.Monad
import Test.Tasty.HUnit
import Control.Concurrent
import Database.Zookeeper
import System.Environment

envKey :: String
envKey = "_ZOOKEEPER_ENDPOINT"

chroot :: String -> String
chroot = ("/test-zookeeper" ++)

getEndpoint :: IO String
getEndpoint = do
  mendpoint <- fmap (lookup envKey) getEnvironment
  case mendpoint of
    Nothing -> return "localhost:2181"
    Just v  -> return v

disclaimer :: IO ()
disclaimer = do
  endpoint <- getEndpoint
  putStrLn ("> This program depends on a zookeeper server. The current endpoint is: " ++ endpoint)
  putStrLn ("> You may override this default with the following env variable: " ++ envKey)

testExists zh = testGroup "exists"
  [ testCase "exists after create" $ do
      let path = chroot "/testExists#1"
      mvar <- newEmptyMVar
      create zh path Nothing OpenAclUnsafe [] (\_ ->
        exists zh path Nothing >>= putMVar mvar . either (const False) (const True))
      takeMVar mvar @? "== Right _"
  , testCase "exists without znode" $ do
      let path = chroot "/testExists#2"
      mvar <- newEmptyMVar
      exists zh path Nothing >>= (@?= Left NoNodeError)
  , testCase "exists(watcher) and create" $ do
      let path = chroot "/testExists#3"
      mvar <- newEmptyMVar
      exists zh path (Just $ watcher mvar) >>= (@?= Left NoNodeError)
      create zh path Nothing OpenAclUnsafe [] (const $ return ())
      takeMVar mvar >>= (@?= (CreatedEvent, Just path))
  , testCase "exists(watcher) and set" $ do
      let path = chroot "/testExists#4"
      mvar <- newEmptyMVar
      create zh path Nothing OpenAclUnsafe [] (\_ -> do
        exists zh path (Just $ watcher mvar)
        set zh path Nothing Nothing
        return ())
      takeMVar mvar >>= (@?= (ChangedEvent, Just path))
  , testCase "exists(watcher) and delete" $ do
      let path = chroot "/testExists#5"
      mvar <- newEmptyMVar
      create zh path Nothing OpenAclUnsafe [] (\_ -> do
        exists zh path (Just $ watcher mvar)
        delete zh path Nothing
        return ())
      takeMVar mvar >>= (@?= (DeletedEvent, Just path))
  ]
    where
      watcher mvar _ event _ mpath = putMVar mvar (event, mpath)

testGet zh = testGroup "get"
  [ testCase "get without znode" $ do
      let path = chroot "/testGet#1"
      mvar <- newEmptyMVar
      get zh path Nothing (putMVar mvar)
      takeMVar mvar >>= (@?= Left NoNodeError)
  , testCase "create(nodata) and get" $ do
      let path = chroot "/testGet#2"
      mvar <- newEmptyMVar
      create zh path Nothing OpenAclUnsafe [] (\_ ->
        get zh path Nothing (putMVar mvar . either (const False) (isNothing . fst)))
      takeMVar mvar @? "== Right (Nothing, _)"
  , testCase "create(data) and get" $ do
      let path = chroot "/testGet#3"
      mvar <- newEmptyMVar
      create zh path (Just "foobar") OpenAclUnsafe [] (\_ ->
        get zh path Nothing (putMVar mvar . either (const False) ((== Just "foobar") . fst)))
      takeMVar mvar @? "== Right (Just \"foobar\", _)"
  , testCase "get(watcher) and set" $ do
      let path = chroot "/testGet#4"
      mvar <- newEmptyMVar
      create zh path Nothing OpenAclUnsafe [] (\_ ->
        get zh path (Just $ watcher mvar) (\_ -> set zh path Nothing Nothing >> return ()))
      takeMVar mvar >>= (@?= (ChangedEvent, Just path))
  , testCase "get(watcher) and delete" $ do
      let path = chroot "/testGet#5"
      mvar <- newEmptyMVar
      create zh path Nothing OpenAclUnsafe [] (\_ ->
        get zh path (Just $ watcher mvar) (\_ -> delete zh path Nothing >> return ()))
      takeMVar mvar >>= (@?= (DeletedEvent, Just path))
  ]
    where
      watcher mvar _ event _ mpath = putMVar mvar (event, mpath)

testOwnsEphemeral zh = testGroup "ownsEphemeral"
  [ testCase "get ephemeral" $ do
    let path = chroot "/testGet#6"
    mvar <- newEmptyMVar
    create zh path Nothing OpenAclUnsafe [Ephemeral] (\_ ->
      get zh path Nothing (\(Right (_, stat)) -> do
        myId <- getClientId zh
        putMVar mvar =<< ownsEphemeral myId stat))
    takeMVar mvar @? "owns ephemeral"
  ]

testGetChildren zh = testGroup "getChildren"
  [ testCase "getChildren without znode" $ do
      let path = chroot "/testGetChildren#1"
      mvar <- newEmptyMVar
      getChildren zh path Nothing (putMVar mvar)
      takeMVar mvar >>= (@?= Left NoNodeError)
  , testCase "getChildren after create" $ do
      let path = chroot "/testGetChildren#2"
      mvar <- newEmptyMVar
      create zh path Nothing OpenAclUnsafe [] (\_ ->
        getChildren zh path Nothing (putMVar mvar))
      takeMVar mvar >>= (@?= Right [])
  , testCase "getChildren with one child" $ do
      let path = chroot "/testGetChildren#3"
      mvar <- newEmptyMVar
      create zh path Nothing OpenAclUnsafe [] (\_ ->
        create zh (path ++ "/1") Nothing OpenAclUnsafe [] (\_ ->
          getChildren zh path Nothing (putMVar mvar)))
      takeMVar mvar >>= (@?= Right ["1"])
  , testCase "getChildren(watcher) and create child" $ do
      let path = chroot "/testGetChildren#4"
      mvar <- newEmptyMVar
      create zh path Nothing OpenAclUnsafe [] (\_ ->
        getChildren zh path (Just $ watcher mvar) (\_ ->
          create zh (path ++ "/1") Nothing OpenAclUnsafe [] (const $ return ())))
      takeMVar mvar >>= (@?= (ChildEvent, Just path))
  , testCase "getChildren(watcher) and delete child" $ do
      let path = chroot "/testGetChildren#5"
      mvar <- newEmptyMVar
      create zh path Nothing OpenAclUnsafe [] (\_ ->
        create zh (path ++ "/1") Nothing OpenAclUnsafe [] (\_ ->
          getChildren zh path (Just $ watcher mvar) (\_ -> do
            delete zh (path ++ "/1") Nothing
            return ())))
      takeMVar mvar >>= (@?= (ChildEvent, Just path))
  ]
    where
      watcher mvar _ event _ mpath = putMVar mvar (event, mpath)

testGetAcl zh = testGroup "getAcl"
  [ testCase "getAcl" $ do
      let path = chroot "/testGetAcl#1"
      mvar <- newEmptyMVar
      create zh path Nothing OpenAclUnsafe [] (\_ ->
        getAcl zh path (putMVar mvar . either (const 0) (countAcls . fst)))
      takeMVar mvar >>= (@?= 1)
  , testCase "getAcl flags" $ do
      let path  = chroot "/testGetAcl#2"
          flags = [ []
                  , [CanRead]
                  , [CanRead, CanAdmin]
                  , [CanRead, CanAdmin, CanWrite]
                  , [CanRead, CanAdmin, CanWrite, CanCreate]
                  , [CanRead, CanAdmin, CanWrite, CanCreate, CanDelete]
                  ]
      forM_ flags $ \flag -> do
        mvar <- newEmptyMVar
        create zh path Nothing (List [Acl "world" "anyone" flag]) [] (\_ -> do
          getAcl zh path (\rc -> do
            delete zh path Nothing
            putMVar mvar (either (const []) (getFlags . fst) rc)))
        takeMVar mvar >>= (@?= flag)
  ]
    where
      countAcls (List xs) = length xs
      countAcls _         = 1

      getFlags (List xs)  = concatMap aclFlags xs
      getFlags _          = []

rmrf :: Zookeeper -> String -> IO ()
rmrf zh path = do
  let childPath name = path ++ "/" ++ name
  mvar <- newEmptyMVar
  getChildren zh path Nothing (putMVar mvar)
  takeMVar mvar >>= either (const $ return ()) (mapM_ (rmrf zh . childPath))
  delete zh path Nothing
  return ()

main :: IO ()
main = do
  disclaimer
  endpoint   <- getEndpoint
  waitState  <- newEmptyMVar
  waitCreate <- newEmptyMVar
  withZookeeper endpoint 5000 (Just $ watcher waitState) Nothing $ \zh -> do
    state <- takeMVar waitState
    case state of
      ConnectedState -> do
        rmrf zh (chroot "")
        create zh (chroot "") Nothing OpenAclUnsafe [] (putMVar waitCreate)
        takeMVar waitCreate
        defaultMain $ testGroup "Zookeeper" [ testGet zh
                                            , testExists zh
                                            , testGetAcl zh
                                            , testGetChildren zh
                                            , testOwnsEphemeral zh
                                            ]
      _              -> exitFailure
    where
      watcher mvar _ _ e _ = putMVar mvar e
