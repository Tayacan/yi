{-# LANGUAGE TemplateHaskell, GeneralizedNewtypeDeriving, DeriveDataTypeable, FlexibleContexts, StandaloneDeriving #-}

-- Copyright (c) 2004-5, Don Stewart - http://www.cse.unsw.edu.au/~dons
-- Copyright (c) 2007-8, JP Bernardy

-- | The top level editor state, and operations on it.

module Yi.Editor where

import Yi.Buffer
import Yi.Config
import Yi.Dynamic
import Yi.KillRing
import Yi.Window
import Yi.Window
import Yi.Event (Event)
import Yi.Style (StyleName, defaultStyle)

import Prelude (map, filter, (!!), takeWhile, length, reverse)
import Yi.Prelude

import Data.Accessor.Basic (fromSetGet)
import Data.Accessor.Template
import Data.Binary
import Data.List (nub, delete, (\\))
import qualified Data.List.PointedList.Circular as PL
import Data.Either (rights)
import Data.Foldable (concatMap)
import qualified Data.DelayList as DelayList
import qualified Data.Map as M
import Data.Maybe
import Data.Typeable
import System.FilePath (splitPath)
import Control.Monad.RWS hiding (get, put, mapM, forM_)
import qualified Data.ByteString.Lazy.UTF8 as LazyUTF8

type Status = ([String],StyleName)
type Statuses = DelayList.DelayList Status

-- | The Editor state
data Editor = Editor {
        bufferStack   :: ![BufferRef]               -- ^ Stack of all the buffers. 
                                                    -- Invariant: never empty
                                                    -- Invariant: first buffer is the current one.
       ,buffers       :: !(M.Map BufferRef FBuffer)
       ,refSupply     :: !Int  -- ^ Supply for buffer and window ids.

       ,tabs_          :: !(PL.PointedList (PL.PointedList Window))

       ,dynamic       :: !(DynamicValues)              -- ^ dynamic components

       ,statusLines   :: !Statuses
       ,killring      :: !Killring
       ,regex         :: !(Maybe SearchExp) -- ^ most recent regex
       ,searchDirection :: !Direction
       ,pendingEvents :: ![Event]                   -- ^ Processed events that didn't yield any action yet.
    }
    deriving Typeable

instance Binary Editor where
    put (Editor bss bs supply ts _dv _sl kr _re _dir _ev) = put bss >> put bs >> put supply >> put ts >> put kr 
    get = do
        bss <- get
        bs <- get
        supply <- get
        ts <- get
        kr <- get
        return $ emptyEditor {bufferStack = bss,
                              buffers = bs,
                              refSupply = supply,
                              tabs_ = ts,
                              killring = kr
                             }

newtype EditorM a = EditorM {fromEditorM :: RWS Config () Editor a}
    deriving (Monad, MonadState Editor, MonadReader Config, Functor)

deriving instance Typeable1 EditorM

instance Applicative EditorM where
  pure = return
  (<*>) = ap

class (Monad m, MonadState Editor m) => MonadEditor m
    where askCfg :: m Config
          withEditor :: EditorM a -> m a
          withEditor f = do
              cfg <- askCfg
              getsAndModify (runEditor cfg f) 
    
liftEditor :: MonadEditor m => EditorM a -> m a
liftEditor = withEditor

instance MonadEditor EditorM where
    askCfg = ask
    withEditor = id

-- | The initial state
emptyEditor :: Editor
emptyEditor = Editor {
        buffers      = M.singleton (bkey buf) buf
       ,tabs_        = PL.singleton (PL.singleton win)
       ,bufferStack  = [bkey buf]
       ,refSupply    = 2
       ,regex        = Nothing
       ,searchDirection = Forward
       ,dynamic      = M.empty
       ,statusLines  = DelayList.insert (maxBound, ([""], defaultStyle)) []
       ,killring     = krEmpty
       ,pendingEvents = []
       }
        where buf = newB 0 (Left "console") (LazyUTF8.fromString "")
              win = (dummyWindow (bkey buf)) {wkey = 1, isMini = False}

-- ---------------------------------------------------------------------

runEditor :: Config -> EditorM a -> Editor -> (Editor, a)
runEditor cfg f e = let (a, e',()) = runRWS (fromEditorM f) cfg e in (e',a)

$(nameDeriveAccessors ''Editor (\n -> Just (n ++ "A")))


-- TODO: replace this by accessor
windows :: Editor -> PL.PointedList Window
windows editor = PL.focus $ tabs_ editor

windowsA :: Accessor Editor (PL.PointedList Window)
windowsA =  PL.focusA . tabsA

tabsA = tabs_A . fixCurrentBufferA_

dynA :: Initializable a => Accessor Editor a
dynA = dynamicValueA . dynamicA

-- ---------------------------------------------------------------------
-- Buffer operations

newRef :: EditorM Int
newRef = do
  modA refSupplyA (+ 1)
  getA refSupplyA

newBufRef :: EditorM BufferRef
newBufRef = BufferRef <$> newRef

-- | Create and fill a new buffer, using contents of string.
-- | Does not focus the window, or make it the current window.
-- | Call newWindowE or switchToBufferE to take care of that.
stringToNewBuffer :: BufferId -- ^ The buffer indentifier
                  -> LazyUTF8.ByteString -- ^ The contents with which to populate the buffer
                  -> EditorM BufferRef
stringToNewBuffer nm cs = do
    u <- newBufRef
    defRegStyle <- configRegionStyle <$> askCfg
    insertBuffer $ setVal regionStyleA defRegStyle $ newB u nm cs
    m <- asks configFundamentalMode
    withGivenBuffer0 u $ setAnyMode m
    return u

insertBuffer :: FBuffer -> EditorM BufferRef
insertBuffer b = getsAndModify $
                 \e -> (let first:bs = bufferStack e in 
                        -- may not be active so don't put it on the top of the stack
                        -- valid since bufferstack is never empty
                        e {bufferStack = nub (first:bkey b:bs),
                           buffers = M.insert (bkey b) b (buffers e)
                          }, bkey b)

-- | Delete a buffer (and release resources associated with it).
deleteBuffer :: BufferRef -> EditorM ()
deleteBuffer k = do
  bs <- gets bufferStack
  ws <- getA windowsA
  case bs of
      (b0:nextB:_) -> do
          let pickOther w = if bufkey w == k then w {bufkey = other} else w
              visibleBuffers = fmap bufkey $ toList ws
              other = head $ (bs \\ visibleBuffers) ++ (delete k bs)
          when (b0 == k) $ do
              -- we delete the currently selected buffer: the next buffer will become active in
              -- the main window, therefore it must be assigned a new window.
              switchToBufferE nextB
          modify $ \e -> e {bufferStack = filter (k /=) $ bufferStack e,
                            buffers = M.delete k (buffers e),
                            tabs_ = fmap (fmap pickOther) (tabs_ e)
                            -- all windows open on that buffer must switch to another buffer.
                           }
      _ -> return () -- Don't delete the last buffer.

-- | Return the buffers we have, /in no particular order/
bufferSet :: Editor -> [FBuffer]
bufferSet = M.elems . buffers

-- | Return a prefix that can be removed from all buffer paths while keeping them
-- unique.
commonNamePrefix :: Editor -> [String]
commonNamePrefix = commonPrefix . fmap (dropLast . splitPath) . rights . fmap (^. identA) . bufferSet
    where dropLast [] = []
          dropLast x = init x
          -- drop the last component, so that it is never hidden.

getBufferStack :: EditorM [FBuffer]
getBufferStack = do
  bufMap <- gets buffers
  gets (fmap (bufMap M.!) . bufferStack)

findBuffer :: BufferRef -> EditorM (Maybe FBuffer)
findBuffer k = gets (M.lookup k . buffers)

-- | Find buffer with this key
findBufferWith :: BufferRef -> Editor -> FBuffer
findBufferWith k e = 
    case M.lookup k (buffers e) of
        Just b  -> b
        Nothing -> error "Editor.findBufferWith: no buffer has this key"


-- | Find buffer with this name
findBufferWithName :: String -> Editor -> [BufferRef]
findBufferWithName n e = map bkey $ filter (\b -> shortIdentString (commonNamePrefix e) b == n) (M.elems $ buffers e)

-- | Find buffer with given name. Fail if not found.
getBufferWithName :: String -> EditorM BufferRef
getBufferWithName bufName = do
  bs <- gets $ findBufferWithName bufName
  case bs of
    [] -> fail ("Buffer not found: " ++ bufName)
    (b:_) -> return b

-- | Make all buffers visible by splitting the current window list.
-- FIXME: rename to displayAllBuffersE; make sure buffers are not open twice.
openAllBuffersE :: EditorM ()
openAllBuffersE = do bs <- gets bufferSet
                     forM_ bs $ (modA windowsA . PL.insertRight =<<) . newWindowE False . bkey

------------------------------------------------------------------------

-- | Return the next buffer
nextBuffer :: EditorM BufferRef
nextBuffer = shiftBuffer 1

-- | Return the prev buffer
prevBuffer :: EditorM BufferRef
prevBuffer = shiftBuffer (negate 1)

-- | Return the buffer using a function applied to the current window's
-- buffer's index.
shiftBuffer :: Int -> EditorM BufferRef
shiftBuffer shift = gets $ \e ->
    let bs  = bufferStack e
        n   = shift `mod` length bs
    in (bs !! n)

------------------------------------------------------------------------

-- | Perform action with any given buffer, using the last window that was used for that buffer.
withGivenBuffer0 :: BufferRef -> BufferM a -> EditorM a
withGivenBuffer0 k f = do
    b <- gets (findBufferWith k)

    withGivenBufferAndWindow0 (b ^. lastActiveWindowA) k f

-- | Perform action with any given buffer
withGivenBufferAndWindow0 :: Window -> BufferRef -> BufferM a -> EditorM a
withGivenBufferAndWindow0 w k f = do
  accum <- asks configKillringAccumulate
  getsAndModify $ \e ->
                        let b = findBufferWith k e
                            (v, us, b') = runBufferFull w b f
                            
                        in (e {buffers = mapAdjust' (const b') k (buffers e),
                               killring = (if accum && all updateIsDelete us
                                           then foldl (.) id 
                                                (reverse [krPut dir (LazyUTF8.toString s) | Delete _ dir s <- us])
                                           else id) 
                                          (killring e)
                              },v)


-- | Perform action with current window's buffer
withBuffer0 :: BufferM a -> EditorM a
withBuffer0 f = do
  w <- getA currentWindowA
  withGivenBufferAndWindow0 w (bufkey w) f

currentWindowA :: Accessor Editor Window
currentWindowA = PL.focusA . windowsA

-- | Return the current buffer
currentBuffer :: Editor -> BufferRef
currentBuffer = head . bufferStack

-----------------------
-- Handling of status

-- | Display a transient message
printMsg :: String -> EditorM ()
printMsg s = printStatus ([s], defaultStyle)

printMsgs :: [String] -> EditorM ()
printMsgs s = printStatus (s, defaultStyle)

printStatus :: Status -> EditorM ()
printStatus = setTmpStatus 1

-- | Set the "background" status line 
setStatus :: Status -> EditorM ()
setStatus = setTmpStatus maxBound

-- | Clear the status line
clrStatus :: EditorM ()
clrStatus = setStatus ([""], defaultStyle)

statusLine :: Editor -> [String]
statusLine = fst . statusLineInfo

statusLineInfo :: Editor -> Status
statusLineInfo = snd . head . statusLines


setTmpStatus :: Int -> Status -> EditorM ()
setTmpStatus delay s = do
  modA statusLinesA $ DelayList.insert (delay, s)
  -- also show in the messages buffer, so we don't loose any message
  bs <- gets (filter (\b -> b ^. identA == Left "messages") . M.elems . buffers)

  b <- case bs of
         (b':_) -> return $ bkey b'
         [] -> stringToNewBuffer (Left "messages") (fromString "")
  withGivenBuffer0 b $ do botB; insertN (show s ++ "\n")


-- ---------------------------------------------------------------------
-- kill-register (vim-style) interface to killring.

-- | Put string into yank register
setRegE :: String -> EditorM ()
setRegE s = modA killringA $ krSet s

-- | Return the contents of the yank register
getRegE :: EditorM String
getRegE = getsA killringA krGet



-- ---------------------------------------------------------------------
-- | Dynamically-extensible state components.
--
-- These hooks are used by keymaps to store values that result from
-- Actions (i.e. that restult from IO), as opposed to the pure values
-- they generate themselves, and can be stored internally.
--
-- The `dynamic' field is a type-indexed map.
--

-- | Retrieve a value from the extensible state
getDynamic :: Initializable a => EditorM a
getDynamic = getA (dynamicValueA . dynamicA)

-- | Insert a value into the extensible state, keyed by its type
setDynamic :: Initializable a => a -> EditorM ()
setDynamic x = putA (dynamicValueA . dynamicA) x

-- | Attach the next buffer in the buffer list
-- to the current window.
nextBufW :: EditorM ()
nextBufW = nextBuffer >>= switchToBufferE

-- | edit the previous buffer in the buffer list
prevBufW :: EditorM ()
prevBufW = prevBuffer >>= switchToBufferE

-- | Like fnewE, create a new buffer filled with the String @s@,
-- Switch the current window to this buffer. Doesn't associate any file
-- with the buffer (unlike fnewE) and so is good for popup internal
-- buffers (like scratch)
newBufferE :: BufferId   -- ^ buffer name
              -> LazyUTF8.ByteString -- ^ buffer contents
              -> EditorM BufferRef
newBufferE f s = do
    b <- stringToNewBuffer f s
    switchToBufferE b
    return b

-- | Create a new window onto the given buffer.
newWindowE :: Bool -> BufferRef -> EditorM Window
newWindowE mini bk = Window mini bk 0 <$> newRef

-- | Attach the specified buffer to the current window
switchToBufferE :: BufferRef -> EditorM ()
switchToBufferE bk = modA (PL.focusA . windowsA) (\w -> w { bufkey = bk })

-- | Attach the specified buffer to some other window than the current one
switchToBufferOtherWindowE :: BufferRef -> EditorM ()
switchToBufferOtherWindowE b = shiftOtherWindow >> switchToBufferE b

-- | Switch to the buffer specified as parameter. If the buffer name is empty, switch to the next buffer.
switchToBufferWithNameE :: String -> EditorM ()
switchToBufferWithNameE "" = nextBufW
switchToBufferWithNameE bufName = switchToBufferE =<< getBufferWithName bufName

-- | Close a buffer.
-- Note: close the current buffer if the empty string is given
closeBufferE :: String -> EditorM ()
closeBufferE nm = deleteBuffer =<< getBufferWithNameOrCurrent nm

getBufferWithNameOrCurrent :: String -> EditorM BufferRef
getBufferWithNameOrCurrent nm = if null nm then gets currentBuffer else getBufferWithName nm


------------------------------------------------------------------------

-- | Close current buffer and window, unless it's the last one.
closeBufferAndWindowE :: EditorM ()
closeBufferAndWindowE = do
  deleteBuffer =<< gets currentBuffer
  tryCloseE

-- | Rotate focus to the next window
nextWinE :: EditorM ()
nextWinE = modA windowsA PL.next

-- | Rotate focus to the previous window
prevWinE :: EditorM ()
prevWinE = modA windowsA PL.previous

-- | A "fake" accessor that fixes the current buffer after a change of the current
-- window. 
-- Enforces invariant that top of buffer stack is the buffer of the current
fixCurrentBufferA_ :: Accessor Editor Editor
fixCurrentBufferA_ = fromSetGet (\new _old -> let 
    ws = windows new
    b = findBufferWith (bufkey $ PL.focus ws) new
    newBufferStack = nub (bkey b : bufferStack new)
    -- make sure we do not hold to old versions.
    in length newBufferStack `seq` new { bufferStack = newBufferStack  } ) id
    

withWindows :: (PL.PointedList Window -> a) -> EditorM a
withWindows = getsA windowsA

withWindow :: (Window -> a) -> EditorM a
withWindow f = getsA (PL.focusA . windowsA) f

findWindowWith :: WindowRef -> Editor -> Window
findWindowWith k e =
    head $ concatMap (\win -> if (wkey win == k) then [win] else []) $ windows e

-- | Return the windows that are currently open on the buffer whose key is given
windowsOnBufferE :: BufferRef -> EditorM [Window]
windowsOnBufferE k = do
  ts <- getA tabsA
  return $ concatMap (concatMap (\win -> if (bufkey win == k) then [win] else [])) ts

-- | Split the current window, opening a second window onto current buffer.
-- TODO: unfold newWindowE here?
splitE :: EditorM ()
splitE = do
  b <- gets currentBuffer
  w <- newWindowE False b
  modA windowsA (PL.insertRight w)

-- | Enlarge the current window
enlargeWinE :: EditorM ()
enlargeWinE = error "enlargeWinE: not implemented"

-- | Shrink the current window
shrinkWinE :: EditorM ()
shrinkWinE = error "shrinkWinE: not implemented"

-- | Creates a new tab containing a window that views the current buffer.
newTabE :: EditorM ()
newTabE = do
    bk <- gets currentBuffer
    win <- newWindowE False bk
    modA tabsA (PL.insertRight (PL.singleton win))

-- | Moves to the next tab in the round robin set of tabs
nextTabE :: EditorM ()
nextTabE = modA tabsA PL.next

-- | Moves to the previous tab in the round robin set of tabs
previousTabE :: EditorM ()
previousTabE = modA tabsA PL.previous

-- | Moves the focused tab to the given index, or to the end if the index is not specified.
moveTab :: Maybe Int -> EditorM ()
moveTab Nothing  = do count <- getsA tabsA PL.length
                      modA tabsA $ fromJust . PL.move count
moveTab (Just n) = do modA tabsA $ fromJust . PL.move n

-- | Close the current window. If there is only one tab open and the tab 
-- contains only one window then do nothing.
tryCloseE :: EditorM ()
tryCloseE = do
    n <- getsA windowsA PL.length
    if n == 1
        -- Could the Maybe response from deleteRight be used instead of the
        -- initial 'if'?
        then modA tabsA (fromJust . PL.deleteRight)
        else modA windowsA (fromJust . PL.deleteRight)

-- | Make the current window the only window on the screen
closeOtherE :: EditorM ()
closeOtherE = modA windowsA PL.deleteOthers

-- | Switch focus to some other window. If none is available, create one.
shiftOtherWindow :: MonadEditor m => m ()
shiftOtherWindow = liftEditor $ do
  len <- withWindows PL.length
  if (len == 1) 
    then splitE
    else nextWinE

-- | Execute the argument in the context of an other window. Create
-- one if necessary. The current window is re-focused after the
-- argument has completed.
withOtherWindow :: MonadEditor m => m a -> m a
withOtherWindow f = do
  shiftOtherWindow
  x <- f
  liftEditor prevWinE
  return x

