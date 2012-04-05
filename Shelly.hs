{-# LANGUAGE ScopedTypeVariables, DeriveDataTypeable, OverloadedStrings,
             MultiParamTypeClasses, FlexibleInstances, TypeSynonymInstances, IncoherentInstances #-}

-- | A module for shell-like / perl-like programming in Haskell.
-- Shelly's focus is entirely on ease of use for those coming from shell scripting.
-- However, it also tries to use modern libraries and techniques to keep things efficient.
--
-- The functionality provided by
-- this module is (unlike standard Haskell filesystem functionality)
-- thread-safe: each ShIO maintains its own environment and its own working
-- directory.
--
-- I highly recommend putting the following at the top of your program,
-- otherwise you will likely need either type annotations or type conversions
--
-- > {-# LANGUAGE OverloadedStrings #-}
-- > {-# LANGUAGE ExtendedDefaultRules #-}
-- > {-# OPTIONS_GHC -fno-warn-type-defaults #-}
-- > import Data.Text.Lazy as LT
-- > default (LT.Text)
module Shelly
       (
         -- * Entering ShIO.
         ShIO, shelly, sub, silently, verbosely, jobs, print_commands

         -- * Running external commands.
         , run, run_, cmd, (-|-), lastStderr, setStdin
         , command, command_, command1, command1_
--         , Sudo(..), run_sudo

         -- * Modifying and querying environment.
         , setenv, getenv, getenv_def, appendToPath

         -- * Environment directory
         , cd, chdir, pwd

         -- * Printing
         , echo, echo_n, echo_err, echo_n_err, inspect

         -- * Querying filesystem.
         , ls, ls', test_e, test_f, test_d, test_s, which, find

         -- * Filename helpers
         , path, absPath, (</>), (<.>)

         -- * Manipulating filesystem.
         , mv, rm_f, rm_rf, cp, cp_r, mkdir, mkdir_p
         , readfile, writefile, appendfile, withTmpDir

         -- * Running external commands asynchronously.
         , background, getBgResult, BackGroundResult

         -- * exiting the program
         , exit, errorExit, terror

         -- * Utilities.
         , (<$>), (<$$>), grep, whenM, unlessM, canonic
         , catchany, catch_sh, catchany_sh
         , MemTime(..), time
         , RunFailed(..)

         -- * convert between Text and FilePath
         , toTextIgnore, toTextWarn, fromText

         -- * Re-exported for your convenience
         , liftIO, when, unless
         ) where

-- TODO:
-- shebang runner that puts wrappers in and invokes
-- convenience for commands that use record arguments
{-
      let oFiles = ("a.o", "b.o")
      let ldOutput x = ("-o", x)

      let def = LD { output = error "", verbose = False, inputs = [] }
      data LD = LD { output :: FilePath, verbose :: Bool, inputs :: [FilePath] } deriving(Data, Typeable)
      instance Runnable LD where
        run :: LD -> IO ()

      class Runnable a where
        run :: a -> ShIO Text

      let ld = def :: LD
      run (ld "foo") { oFiles = [] }
      run ld { oFiles = [] }
      ld = ..magic..
-}

import Prelude hiding ( catch, readFile, FilePath )
import Data.List( isInfixOf )
import Data.Char( isAlphaNum )
import Data.Typeable
import Data.IORef
import Data.Maybe
import System.IO hiding ( readFile, FilePath )
import System.Exit
import System.Environment
import Control.Applicative
import Control.Exception hiding (handle)
import Control.Monad.Reader
import Control.Concurrent
import Data.Time.Clock( getCurrentTime, diffUTCTime  )

import qualified Data.Text.Lazy.IO as TIO
import qualified Data.Text.IO as STIO
import System.Process( runInteractiveProcess, waitForProcess, ProcessHandle )

import qualified Data.Text.Lazy as LT
import Data.Text.Lazy (Text)
import qualified Data.Text.Lazy.Builder as B
import qualified Data.Text as T
import Data.Monoid (mappend)

import Filesystem.Path.CurrentOS hiding (concat, fromText, (</>), (<.>))
import Filesystem
import qualified Filesystem.Path.CurrentOS as FP

import System.PosixCompat.Files( getSymbolicLinkStatus, isSymbolicLink )
import System.Directory ( setPermissions, getPermissions, Permissions(..), getTemporaryDirectory, findExecutable ) 

{- GHC won't default to Text with this
class ShellArgs a where
  toTextArgs :: a -> [Text]

instance ShellArgs Text       where toTextArgs t = [t]
instance ShellArgs FilePath   where toTextArgs t = [toTextIgnore t]
instance ShellArgs [Text]     where toTextArgs = id
instance ShellArgs [FilePath] where toTextArgs = map toTextIgnore

instance ShellArgs (Text, Text) where
  toTextArgs (t1,t2) = [t1, t2]
instance ShellArgs (FilePath, FilePath) where
  toTextArgs (fp1,fp2) = [toTextIgnore fp1, toTextIgnore fp2]
instance ShellArgs (Text, FilePath) where
  toTextArgs (t1, fp1) = [t1, toTextIgnore fp1]
instance ShellArgs (FilePath, Text) where
  toTextArgs (fp1,t1) = [toTextIgnore fp1, t1]

cmd :: (ShellArgs args) => FilePath -> args -> ShIO Text
cmd fp args = run fp $ toTextArgs args
-}

class ToFilePath a where
  toFilePath :: a -> FilePath

instance ToFilePath FilePath where toFilePath = id
instance ToFilePath Text     where toFilePath = fromText
instance ToFilePath T.Text   where toFilePath = FP.fromText
instance ToFilePath String   where toFilePath = FP.fromText . T.pack

class ShellArg a where toTextArg :: a -> Text
instance ShellArg Text     where toTextArg = id
instance ShellArg FilePath where toTextArg = toTextIgnore


-- | For the variadic argument version of 'run' called 'cmd'.
class ShellCommand t where
    cmdAll :: FilePath -> [Text] -> t

instance ShellCommand (ShIO Text) where
    cmdAll fp args = run fp args

-- note that ShIO () actually doesn't compile all the time!
instance ShellCommand (ShIO a) where
    cmdAll fp args = run_ fp args >>
      return (error "No Way! Shelly did not see this coming. Please report this error.")

instance (ShellArg arg, ShellCommand result) => ShellCommand (arg -> result) where
    cmdAll fp acc = \x -> cmdAll fp (acc ++ [toTextArg x])

-- | variadic argument version of run.
-- The syntax is more convenient but it also allows the use of a FilePath as an argument.
-- An argument can be a Text or a FilePath.
-- a FilePath is converted to Text with 'toTextIgnore'.
-- You will need to add the following to your module:
--
-- > {-# LANGUAGE OverloadedStrings #-}
-- > {-# LANGUAGE ExtendedDefaultRules #-}
-- > {-# OPTIONS_GHC -fno-warn-type-defaults #-}
-- > import Shelly
-- > import Data.Text.Lazy as LT
-- > default (LT.Text)
--
cmd :: (ShellCommand result) => FilePath -> result
cmd fp = cmdAll fp []

-- | uses System.FilePath.CurrentOS, but can automatically convert a Text
(</>) :: (ToFilePath filepath) => filepath -> filepath -> FilePath
x </> y = toFilePath x FP.</> toFilePath y

-- | uses System.FilePath.CurrentOS, but can automatically convert a Text
(<.>) :: (ToFilePath filepath) => filepath -> Text -> FilePath
x <.> y = toFilePath x FP.<.> LT.toStrict y


-- | silently uses the Right or Left value of "Filesystem.Path.CurrentOS.toText"
toTextIgnore :: FilePath -> Text
toTextIgnore fp = LT.fromStrict $ case toText fp of
                                    Left  f -> f
                                    Right f -> f

toTextWarn :: FilePath -> ShIO Text
toTextWarn efile = fmap lazy $ case toText efile of
    Left f -> encodeError f >> return f
    Right f -> return f
  where
    encodeError f = echo ("Invalid encoding for file: " `mappend` lazy f)
    lazy = LT.fromStrict

fromText :: Text -> FilePath
fromText = FP.fromText . LT.toStrict

printGetContent :: Handle -> Handle -> IO Text
printGetContent rH wH =
    fmap B.toLazyText $ printFoldHandleLines (B.fromText "") foldBuilder rH wH

getContent :: Handle -> IO Text
getContent h = fmap B.toLazyText $ foldHandleLines (B.fromText "") foldBuilder h

type FoldCallback a = ((a, Text) -> a)

printFoldHandleLines :: a -> FoldCallback a -> Handle -> Handle -> IO a
printFoldHandleLines start foldLine readHandle writeHandle = go start
  where
    go acc = do
      line <- TIO.hGetLine readHandle
      TIO.hPutStrLn writeHandle line >> go (foldLine (acc, line))
     `catchany` \_ -> return acc

foldHandleLines :: a -> FoldCallback a -> Handle -> IO a
foldHandleLines start foldLine readHandle = go start
  where
    go acc = do
      line <- TIO.hGetLine readHandle
      go $ foldLine (acc, line)
     `catchany` \_ -> return acc

data State = State   { sCode :: Int
                     , sStdin :: Maybe Text -- ^ stdin for the command to be run
                     , sStderr :: Text
                     , sDirectory :: FilePath
                     , sVerbose :: Bool
                     , sJobsSem :: QSem
                     , sPrintCommands :: Bool -- ^ print out command
                     , sRun :: FilePath -> [Text] -> ShIO (Handle, Handle, Handle, ProcessHandle)
                     , sEnvironment :: [(String, String)] }

type ShIO a = ReaderT (IORef State) IO a

get :: ShIO State
get = do
  stateVar <- ask 
  liftIO (readIORef stateVar)

put :: State -> ShIO ()
put state = do
  stateVar <- ask 
  liftIO (writeIORef stateVar state)

modify :: (State -> State) -> ShIO ()
modify f = do
  state <- ask 
  liftIO (modifyIORef state f)


gets :: (State -> a) -> ShIO a
gets f = f <$> get

runInteractiveProcess' :: FilePath -> [Text] -> ShIO (Handle, Handle, Handle, ProcessHandle)
runInteractiveProcess' exe args = do
  st <- get
  liftIO $ runInteractiveProcess (unpack exe)
    (map LT.unpack args)
    (Just $ unpack $ sDirectory st)
    (Just $ sEnvironment st)

{-
-- | use for commands requiring usage of sudo. see 'run_sudo'.
--  Use this pattern for priveledge separation
newtype Sudo a = Sudo { sudo :: ShIO a }

-- | require that the caller explicitly state 'sudo'
run_sudo :: Text -> [Text] -> Sudo Text
run_sudo cmd args = Sudo $ run "/usr/bin/sudo" (cmd:args)
-}

-- | A helper to catch any exception (same as
-- @... `catch` \(e :: SomeException) -> ...@).
catchany :: IO a -> (SomeException -> IO a) -> IO a
catchany = catch

-- | Catch an exception in the ShIO monad.
catch_sh :: (Exception e) => ShIO a -> (e -> ShIO a) -> ShIO a
catch_sh a h = do ref <- ask
                  liftIO $ catch (runReaderT a ref) (\e -> runReaderT (h e) ref)

-- | Catch an exception in the ShIO monad.
catchany_sh :: ShIO a -> (SomeException -> ShIO a) -> ShIO a
catchany_sh = catch_sh

-- | Change current working directory of ShIO. This does *not* change the
-- working directory of the process we are running it. Instead, ShIO keeps
-- track of its own workking directory and builds absolute paths internally
-- instead of passing down relative paths. This may have performance
-- repercussions if you are doing hundreds of thousands of filesystem
-- operations. You will want to handle these issues differently in those cases.
cd :: FilePath -> ShIO ()
cd dir = do dir' <- absPath dir
            modify $ \st -> st { sDirectory = dir' }

-- | "cd", execute a ShIO action in the new directory and then pop back to the original directory
chdir :: FilePath -> ShIO a -> ShIO a
chdir dir action = do
  d <- pwd
  cd dir
  r <- action
  cd d
  return r

-- | makes an absolute path. Same as canonic.
-- TODO: use normalise from system-filepath
path :: FilePath -> ShIO FilePath
path = canonic

-- | makes an absolute path. @path@ will also normalize
absPath :: FilePath -> ShIO FilePath
absPath p | relative p = (FP.</> p) <$> gets sDirectory
          | otherwise = return p
  
-- | apply a String IO operations to a Text FilePath
{-
liftStringIO :: (String -> IO String) -> FilePath -> ShIO FilePath
liftStringIO f = liftIO . f . unpack >=> return . pack

-- | @asString f = pack . f . unpack@
asString :: (String -> String) -> FilePath -> FilePath
asString f = pack . f . unpack
-}

unpack :: FilePath -> String
unpack = encodeString

pack :: String -> FilePath
pack = decodeString

-- | Currently a "renameFile" wrapper. TODO: Support cross-filesystem
-- move. TODO: Support directory paths in the second parameter, like in "cp".
mv :: FilePath -> FilePath -> ShIO ()
mv a b = do a' <- absPath a
            b' <- absPath b
            liftIO $ rename a' b'

-- | Get back [Text] instead of [FilePath]
ls' :: FilePath -> ShIO [Text]
ls' fp = do
    efiles <- ls fp
    mapM toTextWarn efiles

-- | List directory contents. Does *not* include \".\" and \"..\", but it does
-- include (other) hidden files.
ls :: FilePath -> ShIO [FilePath]
ls = path >=> liftIO . listDirectory

-- | List directory recursively (like the POSIX utility "find").
find :: FilePath -> ShIO [FilePath]
find dir = do bits <- ls dir
              subDir <- forM bits $ \x -> do
                ex <- test_d $ dir FP.</> x
                sym <- test_s $ dir FP.</> x
                if ex && not sym then find (dir FP.</> x)
                                 else return []
              return $ map (dir FP.</>) bits ++ concat subDir

-- | Obtain the current (ShIO) working directory.
pwd :: ShIO FilePath
pwd = gets sDirectory

-- | Echo text to standard (error, when using _err variants) output. The _n
-- variants do not print a final newline.
echo, echo_n, echo_err, echo_n_err :: Text -> ShIO ()
echo       = liftIO . TIO.putStrLn
echo_n     = liftIO . (>> hFlush System.IO.stdout) . TIO.putStr
echo_err   = liftIO . TIO.hPutStrLn stderr
echo_n_err = liftIO . (>> hFlush stderr) . TIO.hPutStr stderr

exit :: Int -> ShIO ()
exit 0 = liftIO $ exitWith ExitSuccess
exit n = liftIO $ exitWith (ExitFailure n)

errorExit :: Text -> ShIO ()
errorExit msg = echo msg >> exit 1

-- | fail that takes a Text
terror :: Text -> ShIO a
terror = fail . LT.unpack

-- | a print lifted into ShIO
inspect :: (Show s) => s -> ShIO ()
inspect = liftIO . print

-- | Create a new directory (fails if the directory exists).
mkdir :: FilePath -> ShIO ()
mkdir = absPath >=> liftIO . createDirectory False

-- | Create a new directory, including parents (succeeds if the directory
-- already exists).
mkdir_p :: FilePath -> ShIO ()
mkdir_p = absPath >=> liftIO . createTree

-- | Get a full path to an executable on @PATH@, if exists. FIXME does not
-- respect setenv'd environment and uses @PATH@ inherited from the process
-- environment.
which :: FilePath -> ShIO (Maybe FilePath)
which =
  liftIO . findExecutable . unpack >=> return . fmap pack 

-- | Obtain a (reasonably) canonic file path to a filesystem object. Based on
-- "canonicalizePath" in FileSystem.
canonic :: FilePath -> ShIO FilePath
canonic = absPath >=> liftIO . canonicalizePath

-- | A monadic-conditional version of the "when" guard.
whenM :: Monad m => m Bool -> m () -> m ()
whenM c a = c >>= \res -> when res a

-- | A monadic-conditional version of the "unless" guard.
unlessM :: Monad m => m Bool -> m () -> m ()
unlessM c a = c >>= \res -> unless res a

-- | Does a path point to an existing filesystem object?
test_e :: FilePath -> ShIO Bool
test_e f = do
  fs <- absPath f
  liftIO $ do
    file <- isFile fs
    if file then return True else isDirectory fs

-- | Does a path point to an existing file?
test_f :: FilePath -> ShIO Bool
test_f = absPath >=> liftIO . isFile

-- | Does a path point to an existing directory?
test_d :: FilePath -> ShIO Bool
test_d = absPath >=> liftIO . isDirectory

-- | Does a path point to a symlink?
test_s :: FilePath -> ShIO Bool
test_s = absPath >=> liftIO . \f -> do
  stat <- getSymbolicLinkStatus (unpack f)
  return $ isSymbolicLink stat

-- | A swiss army cannon for removing things. Actually this goes farther than a
-- normal rm -rf, as it will circumvent permission problems for the files we
-- own. Use carefully.
rm_rf :: FilePath -> ShIO ()
rm_rf f = absPath f >>= \f' -> do
  whenM (test_d f) $ do
    _<- find f' >>= mapM (\file -> liftIO_ $ fixPermissions (unpack file) `catchany` \_ -> return ())
    liftIO_ $ removeTree f'
  whenM (test_f f) $ rm_f f'
  where fixPermissions file =
          do permissions <- liftIO $ getPermissions file
             let deletable = permissions { readable = True, writable = True, executable = True }
             liftIO $ setPermissions file deletable

-- | Remove a file. Does not fail if the file already is not there. Does fail
-- if the file is not a file.
rm_f :: FilePath -> ShIO ()
rm_f f = whenM (test_e f) $ absPath f >>= liftIO . removeFile

-- | Set an environment variable. The environment is maintained in ShIO
-- internally, and is passed to any external commands to be executed.
setenv :: Text -> Text -> ShIO ()
setenv k v =
  let (kStr, vStr) = (LT.unpack k, LT.unpack v)
      wibble env = (kStr, vStr) : filter ((/=kStr).fst) env
   in modify $ \x -> x { sEnvironment = wibble $ sEnvironment x }

-- | add the filepath onto the PATH env variable
appendToPath :: FilePath -> ShIO ()
appendToPath filepath = do
  tp <- toTextWarn filepath
  pe <- getenv path_env
  setenv path_env $ pe `mappend` ":" `mappend` tp
  where
    path_env = "PATH"

-- | Fetch the current value of an environment variable. Both empty and
-- non-existent variables give empty string as a result.
getenv :: Text -> ShIO Text
getenv k = getenv_def k ""

-- | Fetch the current value of an environment variable. Both empty and
-- non-existent variables give the default value as a result
getenv_def :: Text -> Text -> ShIO Text
getenv_def k d = gets sEnvironment >>=
  return . LT.pack . fromMaybe (LT.unpack d) . lookup (LT.unpack k)

-- | Create a sub-ShIO in which external command outputs are not echoed. See "sub".
silently :: ShIO a -> ShIO a
silently a = sub $ modify (\x -> x { sVerbose = False }) >> a

-- | Create a sub-ShIO in which external command outputs are echoed. See "sub".
verbosely :: ShIO a -> ShIO a
verbosely a = sub $ modify (\x -> x { sVerbose = True }) >> a

-- | Create a sub-ShIO which has limits the max number of background tasks.
-- See "sub".  By default the limit is `maxBound :: Int` but can be adjusted
-- by customizing the jobs state.  Note that this limit is per `ShIO` instance,
-- two parallel executions inside the `ShIO` monad will effectively double
-- this limit.
jobs :: Int -> ShIO a -> ShIO a
jobs mx a = do
  sem <- liftIO $ newQSem mx
  sub $ modify (\x -> x { sJobsSem = sem }) >> a

-- | Type returned by tasks run asynchronously in the background.
newtype BackGroundResult a = BGResult (MVar a)

-- | Returns the result from a backgrounded task.  Blocks until
-- the task completes.
getBgResult :: BackGroundResult a -> IO a
getBgResult (BGResult mvar) = do
  takeMVar mvar

-- | Run the `ShIO` task asynchronously in the background, returns
-- the `BackGroundResult a` immediately, see "getBgResult".
-- The subtask will inherit the current ShIO context, including
-- current task count.  This means that if the asynchronous task
-- also calls background the max jobs limit must be sufficient for
-- the parent and all children.
background :: ShIO a -> ShIO (BackGroundResult a)
background proc = do
  state <- get
  mvar <- liftIO newEmptyMVar
  _ <- liftIO $ forkIO $ do
    waitQSem (sJobsSem state)
    result <- shelly $ (put state >> proc)
    signalQSem (sJobsSem state)
    liftIO $ putMVar mvar result
  return $ BGResult mvar


-- | Create a sub-ShIO in which external command outputs are echoed. See "sub".
print_commands :: ShIO a -> ShIO a
print_commands a = sub $ modify (\x -> x { sPrintCommands = True }) >> a

-- | Enter a sub-ShIO that inherits the environment and working directory
-- The original state will be restored when the sub-ShIO completes.
 --Exceptions are propagated normally.
sub :: ShIO a -> ShIO a
sub a = do
  state <- get
  r <- a `catch_sh` (\(e :: SomeException) -> put state >> throw e)
  put state
  return r

-- | Enter a ShIO from (Monad)IO. The environment and working directories are
-- inherited from the current process-wide values. Any subsequent changes in
-- processwide working directory or environment are not reflected in the
-- running ShIO.
shelly :: MonadIO m => ShIO a -> m a
shelly a = do
  env <- liftIO getEnvironment
  dir <- liftIO getWorkingDirectory
  sem <- liftIO $ newQSem maxBound
  let def  = State { sCode = 0
                   , sStdin = Nothing
                   , sStderr = LT.empty
                   , sVerbose = True
                   , sJobsSem = sem
                   , sPrintCommands = False
                   , sRun = runInteractiveProcess'
                   , sEnvironment = env
                   , sDirectory = dir }
  stref <- liftIO $ newIORef def
  liftIO $ runReaderT a stref

data RunFailed = RunFailed FilePath [Text] Int Text deriving (Typeable)

instance Show RunFailed where
  show (RunFailed exe args code errs) =
    "error running " ++
      unpack exe ++ " " ++ show args ++
      ": exit status " ++ show code ++ ":\n" ++ LT.unpack errs

instance Exception RunFailed


-- | Execute an external command. Takes the command name (no shell allowed,
-- just a name of something that can be found via @PATH@; FIXME: setenv'd
-- @PATH@ is not taken into account, only the one inherited from the actual
-- outside environment). Nothing is provided on "stdin" of the process, and
-- "stdout" and "stderr" are collected and stored. The "stdout" is returned as
-- a result of "run", and complete stderr output is available after the fact using
-- "lastStderr" 
--
-- All of the stdout output will be loaded into memory
-- You can avoid this but still consume the result by using "run'",
-- or if you need to process the output than "runFoldLines"
run :: FilePath -> [Text] -> ShIO Text
run exe args = fmap B.toLazyText $ runFoldLines (B.fromText "") foldBuilder exe args

foldBuilder :: (B.Builder, Text) -> B.Builder
foldBuilder (b, line) = b `mappend` B.fromLazyText line `mappend` B.singleton '\n'


-- | bind some arguments to run for re-use
-- Example: @monit = command "monit" ["-c", "monitrc"]@
command :: FilePath -> [Text] -> [Text] -> ShIO Text
command com args more_args = run com (args ++ more_args)

-- | bind some arguments to "run_" for re-use
-- Example: @monit_ = command_ "monit" ["-c", "monitrc"]@
command_ :: FilePath -> [Text] -> [Text] -> ShIO ()
command_ com args more_args = run_ com (args ++ more_args)

-- | bind some arguments to run for re-use, and expect 1 argument
-- Example: @git = command1 "git" []; git "pull" ["origin", "master"]@
command1 :: FilePath -> [Text] -> Text -> [Text] -> ShIO Text
command1 com args one_arg more_args = run com ([one_arg] ++ args ++ more_args)

-- | bind some arguments to run for re-use, and expect 1 argument
-- Example: @git_ = command1_ "git" []; git+ "pull" ["origin", "master"]@
command1_ :: FilePath -> [Text] -> Text -> [Text] -> ShIO ()
command1_ com args one_arg more_args = run_ com ([one_arg] ++ args ++ more_args)

-- the same as "run", but return () instead of the stdout content
run_ :: FilePath -> [Text] -> ShIO ()
run_ = runFoldLines () (\(_, _) -> ())

liftIO_ :: IO a -> ShIO ()
liftIO_ action = liftIO action >> return ()

-- same as "run", but fold over stdout as it is read to avoid keeping it in memory
-- stderr is still placed in memory (this could be changed in the future)
runFoldLines :: a -> FoldCallback a -> FilePath -> [Text] -> ShIO a
runFoldLines start cb exe args = do
    state <- get
    when (sPrintCommands state) $ do
      c <- toTextWarn exe
      echo $ LT.intercalate " " (c:args)
    (inH,outH,errH,procH) <- sRun state exe args

    errV <- liftIO newEmptyMVar
    outV <- liftIO newEmptyMVar
    if sVerbose state
      then do
        liftIO_ $ forkIO $ printGetContent errH stderr >>= putMVar errV
        liftIO_ $ forkIO $ printFoldHandleLines start cb outH stdout >>= putMVar outV
      else do
        liftIO_ $ forkIO $ getContent errH >>= putMVar errV
        liftIO_ $ forkIO $ foldHandleLines start cb outH >>= putMVar outV

    -- If input was provided write it to the input handle.
    case sStdin state of
      Just input ->
        liftIO $ TIO.hPutStr inH input >> hClose inH
        -- stdin is cleared from state below
      Nothing -> return ()

    errs <- liftIO $ takeMVar errV
    outs <- liftIO $ takeMVar outV
    ex <- liftIO $ waitForProcess procH


    let code = case ex of
                 ExitSuccess -> 0
                 ExitFailure n -> n
    put $ state {
       sStdin = Nothing
     , sStderr = errs
     , sCode = code
    }
    case ex of
      ExitSuccess   -> return outs
      ExitFailure n -> throw $ RunFailed exe args n errs

-- | The output of last external command. See "run".
lastStderr :: ShIO Text
lastStderr = gets sStderr

-- | set the stdin to be used and cleared by the next "run".
setStdin :: Text -> ShIO ()
setStdin input = modify $ \st -> st { sStdin = Just input }

-- | Pipe operator. set the stdout the first command as the stdin of the second.
(-|-) :: ShIO Text -> ShIO b -> ShIO b
one -|- two = do
  res <- one
  setStdin res
  two

data MemTime = MemTime Rational Double deriving (Read, Show, Ord, Eq)

-- | Run a ShIO computation and collect timing (TODO: and memory) information.
time :: ShIO a -> ShIO (MemTime, a)
time what = sub $ do -- TODO track memory usage as well
  t <- liftIO getCurrentTime
  res <- what
  t' <- liftIO getCurrentTime
  let mt = MemTime 0 (realToFrac $ diffUTCTime t' t)
  return (mt, res)

{-
    stats_f <- liftIO $
      do tmpdir <- getTemporaryDirectory
         (f, h) <- openTempFile tmpdir "darcs-stats-XXXX"
         hClose h
         return f
    let args = args' ++ ["+RTS", "-s" ++ stats_f, "-RTS"]
    ...
    stats <- liftIO $ do c <- readFile' stats_f
                         removeFile stats_f `catchany` \e -> hPutStrLn stderr (show e)
                         return c
                       `catchany` \_ -> return ""
    let bytes = (stats =~ "([0-9, ]+) M[bB] total memory in use") :: String
        mem = case length bytes of
          0 -> 0
          _ -> (read (filter (`elem` "0123456789") bytes) :: Int)
    recordMemoryUsed $ mem * 1024 * 1024
    return res
-}

-- | Copy a file, or a directory recursively.
cp_r :: FilePath -> FilePath -> ShIO ()
cp_r from to = do
    whenM (test_d from) $
      mkdir to >> ls from >>= mapM_ (\item -> cp_r (from FP.</> item) (to FP.</> item))
    whenM (test_f from) $ cp from to

-- | Copy a file. The second path could be a directory, in which case the
-- original file name is used, in that directory.
cp :: FilePath -> FilePath -> ShIO ()
cp from to = do
  from' <- absPath from
  to' <- absPath to
  to_dir <- test_d to
  liftIO $ copyFile from' $ if to_dir then to' FP.</> filename from else to'

class PredicateLike pattern hay where
  match :: pattern -> hay -> Bool

instance PredicateLike (a -> Bool) a where
  match = id

instance (Eq a) => PredicateLike [a] [a] where
  match pat = (pat `isInfixOf`)

-- | Like filter, but more conveniently used with String lists, where a
-- substring match (TODO: also provide regexps, and maybe globs) is expressed as
--  @grep \"needle\" [ \"the\", \"stack\", \"of\", \"hay\" ]@. Boolean
-- predicates just like with "filter" are supported too:
-- @grep (\"fun\" `isPrefixOf`) [...]@.
grep :: (PredicateLike pattern hay) => pattern -> [hay] -> [hay]
grep p = filter (match p)

-- | A functor-lifting function composition.
(<$$>) :: (Functor m) => (b -> c) -> (a -> m b) -> a -> m c
f <$$> v = fmap f . v

-- | Create a temporary directory and pass it as a parameter to a ShIO
-- computation. The directory is nuked afterwards.
withTmpDir :: (FilePath -> ShIO a) -> ShIO a
withTmpDir act = do
  dir <- liftIO getTemporaryDirectory
  tid <- liftIO myThreadId
  (pS, handle) <- liftIO $ openTempFile dir ("tmp"++filter isAlphaNum (show tid))
  let p = pack pS
  liftIO $ hClose handle -- required on windows
  rm_f p
  mkdir p
  a <- act p`catch_sh` \(e :: SomeException) -> rm_rf p >> throw e
  rm_rf p
  return a

-- | Write a Lazy Text to a file.
writefile :: FilePath -> Text -> ShIO ()
writefile f bits = absPath f >>= \f' -> liftIO (TIO.writeFile (unpack f') bits)

-- | Append a Lazy Text to a file.
appendfile :: FilePath -> Text -> ShIO ()
appendfile f bits = absPath f >>= \f' -> liftIO (TIO.appendFile (unpack f') bits)

-- | (Strictly) read file into a Text.
-- All other functions use Lazy Text.
-- So Internally this reads a file as strict text and then converts it to lazy text, which is inefficient
readfile :: FilePath -> ShIO Text
readfile =
  absPath >=> fmap LT.fromStrict . liftIO . STIO.readFile . unpack
