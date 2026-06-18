{-# LANGUAGE BangPatterns #-}

import Data.ByteString.Builder
import qualified Data.ByteString.Lazy as LBS
import Data.List (foldl')
import Data.Word (Word8, Word32)
import System.Environment (getArgs)
import Text.Printf (printf)
import Data.Time.Clock (diffUTCTime, getCurrentTime)

data Options = Options
  { optWidth :: !Int
  , optHeight :: !Int
  , optOutput :: !FilePath
  }

data Vec = Vec !Double !Double !Double

data Ray = Ray
  { rayStart :: !Vec
  , rayDir :: !Vec
  }

data RgbColor = RgbColor !Word8 !Word8 !Word8 !Word8

data Color = Color !Double !Double !Double

data Camera = Camera
  { cameraPos :: !Vec
  , cameraForward :: !Vec
  , cameraRight :: !Vec
  , cameraUp :: !Vec
  }

data Surface = Shiny | Checkerboard

data SurfaceProps = SurfaceProps
  { propDiffuse :: !Color
  , propSpecular :: !Color
  , propReflect :: !Double
  , propRoughness :: !Double
  }

data Thing
  = Sphere !Vec !Double !Surface
  | Plane !Vec !Double !Surface

data Light = Light !Vec !Color

data Scene = Scene
  { sceneCamera :: !Camera
  , sceneThings :: ![Thing]
  , sceneLights :: ![Light]
  }

data Intersection = Intersection
  { interThing :: !Thing
  , interRay :: !Ray
  , interDist :: !Double
  }

white, grey, black, background, defaultColor :: Color
white = Color 1.0 1.0 1.0
grey = Color 0.5 0.5 0.5
black = Color 0.0 0.0 0.0
background = black
defaultColor = black

main :: IO ()
main = do
  options <- parseOptions <$> getArgs
  let width = optWidth options
      height = optHeight options
      output = optOutput options
  start <- getCurrentTime
  let image = render scene width height
  end <- forceImage image `seq` getCurrentTime
  saveBmp output width height image
  let elapsedMs = realToFrac (diffUTCTime end start) * 1000.0 :: Double
  printf "render time_ms=%.4f width=%d height=%d output=\"%s\"\n" elapsedMs width height output

parseOptions :: [String] -> Options
parseOptions = go (Options 500 500 "haskell-ray.bmp")
  where
    go !options [] = options
    go !options ("--width":value:rest) = go options { optWidth = readInt value (optWidth options) } rest
    go !options ("--height":value:rest) = go options { optHeight = readInt value (optHeight options) } rest
    go !options ("--output":value:rest) = go options { optOutput = value } rest
    go !options (_:rest) = go options rest

readInt :: String -> Int -> Int
readInt value fallback =
  case reads value of
    [(number, "")] -> number
    _ -> fallback

scene :: Scene
scene =
  Scene
    (mkCamera (Vec 3.0 2.0 4.0) (Vec (-1.0) 0.5 0.0))
    [ Plane (Vec 0.0 1.0 0.0) 0.0 Checkerboard
    , Sphere (Vec 0.0 1.0 (-0.25)) 1.0 Shiny
    , Sphere (Vec (-1.0) 0.5 1.5) 0.5 Shiny
    ]
    [ Light (Vec (-2.0) 2.5 0.0) (Color 0.49 0.07 0.07)
    , Light (Vec 1.5 2.5 1.5) (Color 0.07 0.07 0.49)
    , Light (Vec 1.5 2.5 (-1.5)) (Color 0.07 0.49 0.071)
    , Light (Vec 0.0 3.5 0.0) (Color 0.21 0.21 0.35)
    ]

render :: Scene -> Int -> Int -> [RgbColor]
render sc width height =
  [ toRgbColor (traceRay sc (Ray cameraPosition (getPoint cam x y width height)) 0)
  | y <- [0 .. height - 1]
  , x <- [0 .. width - 1]
  ]
  where
    cam = sceneCamera sc
    cameraPosition = cameraPos cam

forceImage :: [RgbColor] -> Int
forceImage = foldl' forcePixel 0
  where
    forcePixel !acc (RgbColor b g r a) =
      acc + fromIntegral b + fromIntegral g + fromIntegral r + fromIntegral a

maxDepth :: Int
maxDepth = 5

traceRay :: Scene -> Ray -> Int -> Color
traceRay sc ray depth =
  case intersections sc ray of
    Just isect -> shade sc isect depth
    Nothing -> background

shade :: Scene -> Intersection -> Int -> Color
shade sc isect depth =
  naturalColor `colorAdd` reflectedColor
  where
    d = rayDir (interRay isect)
    pos = vecAdd (vecScale (interDist isect) d) (rayStart (interRay isect))
    normal = thingNormal (interThing isect) pos
    reflectDir = vecSub d (vecScale (2.0 * dot normal d) normal)
    surface = surfaceProps (thingSurface (interThing isect)) pos
    naturalColor = foldl' addLight background (sceneLights sc)
    reflectedColor =
      if depth >= maxDepth
        then grey
        else colorScale (propReflect surface) (traceRay sc (Ray pos reflectDir) (depth + 1))

    addLight color light@(Light lightPos lightColor) =
      if isInShadow
        then color
        else color `colorAdd` diffuseColor `colorAdd` specularColor
      where
        ldis = vecSub lightPos pos
        livec = norm ldis
        shadow = intersections sc (Ray pos livec)
        isInShadow =
          case shadow of
            Just neatIsect -> interDist neatIsect <= len ldis
            Nothing -> False
        illum = dot livec normal
        lcolor =
          if illum > 0.0
            then colorScale illum lightColor
            else defaultColor
        specular = dot livec (norm reflectDir)
        scolor =
          if specular > 0.0
            then colorScale (specular ** propRoughness surface) lightColor
            else defaultColor
        diffuseColor = propDiffuse surface `colorMul` lcolor
        specularColor = propSpecular surface `colorMul` scolor

intersections :: Scene -> Ray -> Maybe Intersection
intersections sc ray = foldl' closest Nothing (sceneThings sc)
  where
    closest best thing =
      case intersectThing thing ray of
        Nothing -> best
        Just isect ->
          case best of
            Nothing -> Just isect
            Just current ->
              if interDist isect < interDist current
                then Just isect
                else best

intersectThing :: Thing -> Ray -> Maybe Intersection
intersectThing thing@(Sphere center radius surface) ray =
  if dist == 0.0
    then Nothing
    else Just (Intersection thing ray dist)
  where
    radius2 = radius * radius
    eo = vecSub center (rayStart ray)
    v = dot eo (rayDir ray)
    disc = radius2 - (dot eo eo - v * v)
    dist =
      if v >= 0.0 && disc >= 0.0
        then v - sqrt disc
        else 0.0
intersectThing thing@(Plane normal offset surface) ray =
  if denom > 0.0
    then Nothing
    else Just (Intersection thing ray dist)
  where
    denom = dot normal (rayDir ray)
    dist = (dot normal (rayStart ray) + offset) / (-denom)

thingNormal :: Thing -> Vec -> Vec
thingNormal (Sphere center _ _) pos = norm (vecSub pos center)
thingNormal (Plane normal _ _) _ = normal

thingSurface :: Thing -> Surface
thingSurface (Sphere _ _ surface) = surface
thingSurface (Plane _ _ surface) = surface

surfaceProps :: Surface -> Vec -> SurfaceProps
surfaceProps Shiny _ = SurfaceProps white grey 0.7 250.0
surfaceProps Checkerboard (Vec x _ z) =
  if odd (floor z + floor x)
    then SurfaceProps white white 0.1 250.0
    else SurfaceProps black white 0.7 250.0

mkCamera :: Vec -> Vec -> Camera
mkCamera pos lookAt =
  Camera pos forward right up
  where
    down = Vec 0.0 (-1.0) 0.0
    forward = norm (vecSub lookAt pos)
    right = vecScale 1.5 (norm (cross forward down))
    up = vecScale 1.5 (norm (cross forward right))

getPoint :: Camera -> Int -> Int -> Int -> Int -> Vec
getPoint cam x y width height =
  norm (cameraForward cam `vecAdd` vecScale recenterX (cameraRight cam) `vecAdd` vecScale recenterY (cameraUp cam))
  where
    recenterX = (fromIntegral x - fromIntegral width / 2.0) / 2.0 / fromIntegral width
    recenterY = -(fromIntegral y - fromIntegral height / 2.0) / 2.0 / fromIntegral height

dot :: Vec -> Vec -> Double
dot (Vec ax ay az) (Vec bx by bz) = ax * bx + ay * by + az * bz

len :: Vec -> Double
len (Vec x y z) = sqrt (x * x + y * y + z * z)

norm :: Vec -> Vec
norm v =
  if lengthValue == 0.0
    then vecScale (1.0 / 0.0) v
    else vecScale (1.0 / lengthValue) v
  where
    lengthValue = len v

cross :: Vec -> Vec -> Vec
cross (Vec ax ay az) (Vec bx by bz) =
  Vec
    (ay * bz - az * by)
    (az * bx - ax * bz)
    (ax * by - ay * bx)

vecAdd :: Vec -> Vec -> Vec
vecAdd (Vec ax ay az) (Vec bx by bz) = Vec (ax + bx) (ay + by) (az + bz)

vecSub :: Vec -> Vec -> Vec
vecSub (Vec ax ay az) (Vec bx by bz) = Vec (ax - bx) (ay - by) (az - bz)

vecScale :: Double -> Vec -> Vec
vecScale k (Vec x y z) = Vec (k * x) (k * y) (k * z)

colorAdd :: Color -> Color -> Color
colorAdd (Color ar ag ab) (Color br bg bb) = Color (ar + br) (ag + bg) (ab + bb)

colorMul :: Color -> Color -> Color
colorMul (Color ar ag ab) (Color br bg bb) = Color (ar * br) (ag * bg) (ab * bb)

colorScale :: Double -> Color -> Color
colorScale k (Color r g b) = Color (k * r) (k * g) (k * b)

toRgbColor :: Color -> RgbColor
toRgbColor (Color r g b) = RgbColor (clamp b) (clamp g) (clamp r) 255

clamp :: Double -> Word8
clamp c
  | c > 1.0 = 255
  | c < 0.0 = 0
  | otherwise = floor (c * 255.0)

saveBmp :: FilePath -> Int -> Int -> [RgbColor] -> IO ()
saveBmp fileName width height pixels =
  LBS.writeFile fileName (toLazyByteString (fileHeader <> infoHeader <> pixelData))
  where
    fileHeaderSize = 14 :: Word32
    infoHeaderSize = 40 :: Word32
    offBits = fileHeaderSize + infoHeaderSize
    imageSize = fromIntegral (width * height * 4) :: Word32
    fileSize = offBits + imageSize
    fileHeader =
      word16LE 0x4D42
        <> word32LE fileSize
        <> word16LE 0
        <> word16LE 0
        <> word32LE offBits
    infoHeader =
      word32LE infoHeaderSize
        <> int32LE (fromIntegral width)
        <> int32LE (fromIntegral (-height))
        <> word16LE 1
        <> word16LE 32
        <> word32LE 0
        <> word32LE imageSize
        <> int32LE 0
        <> int32LE 0
        <> word32LE 0
        <> word32LE 0
    pixelData = mconcat (map pixelBuilder pixels)

pixelBuilder :: RgbColor -> Builder
pixelBuilder (RgbColor b g r a) = word8 b <> word8 g <> word8 r <> word8 a
