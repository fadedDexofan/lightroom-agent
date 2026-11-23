export const MASK_TYPES = [
  { name: "subject", label: "Subject", stored: { MaskSubType: 1 } },
  { name: "sky", label: "Sky", stored: { MaskSubType: 2 } },
  { name: "background", label: "Background", stored: { MaskSubType: 0, MaskSubCategoryID: 22 } },
] as const;

export const MASK_TYPE_NAMES = MASK_TYPES.map((type) => type.name);

export const PEOPLE_MASK_PARTS = [
  { name: "face_skin", category: 2, label: "Facial Skin" },
  { name: "iris_and_pupil", category: 3, label: "Iris and Pupil" },
  { name: "body_skin", category: 4, label: "Body Skin" },
  { name: "hair", category: 5, label: "Hair" },
  { name: "lips", category: 6, label: "Lips" },
  { name: "facial_hair", category: 7, label: "Facial Hair" },
  { name: "eye_sclera", category: 8, label: "Eye Sclera" },
  { name: "eyebrows", category: 9, label: "Eyebrows" },
  { name: "clothes", category: 11, label: "Clothes" },
  { name: "teeth", category: 12, label: "Teeth" },
  { name: "entire_person", category: 13, label: "Person" },
] as const;

export const PEOPLE_MASK_PART_NAMES = PEOPLE_MASK_PARTS.map((part) => part.name);

export const LANDSCAPE_MASK_CATEGORIES = [
  { name: "architecture", category: 50001, label: "Architecture" },
  { name: "mountains", category: 50002, label: "Mountains" },
  { name: "artificial_ground", category: 50003, label: "Artificial Ground" },
  { name: "natural_ground", category: 50004, label: "Natural Ground" },
  { name: "vegetation", category: 50005, label: "Vegetation" },
  { name: "sky", category: 50006, label: "Sky" },
  { name: "water", category: 50007, label: "Water" },
  { name: "snow", category: 50008, label: "Snow" },
] as const;

export const LANDSCAPE_MASK_CATEGORY_NAMES = LANDSCAPE_MASK_CATEGORIES.map((category) => category.name);

export const MASK_CURVE_CHANNELS = [
  { name: "main", stored: "MainCurve", extended: "ExtendedMainCurve" },
  { name: "red", stored: "RedCurve", extended: "ExtendedRedCurve" },
  { name: "green", stored: "GreenCurve", extended: "ExtendedGreenCurve" },
  { name: "blue", stored: "BlueCurve", extended: "ExtendedBlueCurve" },
] as const;

export const TONE_CURVE_CHANNELS = [
  { stored: "ToneCurvePV2012", extended: "ExtendedToneCurvePV2012" },
  { stored: "ToneCurvePV2012Red", extended: "ExtendedToneCurvePV2012Red" },
  { stored: "ToneCurvePV2012Green", extended: "ExtendedToneCurvePV2012Green" },
  { stored: "ToneCurvePV2012Blue", extended: "ExtendedToneCurvePV2012Blue" },
] as const;

export const POINT_CURVE_MAX_PAIRS = 16;

export const STORED_MASK_DECIMAL_PLACES = 6;

export const MASK_CURVE_CHANNEL_NAMES = MASK_CURVE_CHANNELS.map((channel) => channel.name);

export const PHOTO_FLAGS = [
  { name: "pick", pickStatus: 1 },
  { name: "reject", pickStatus: -1 },
  { name: "none", pickStatus: 0 },
] as const;

export const PHOTO_FLAG_NAMES = PHOTO_FLAGS.map((flag) => flag.name);

export const COLOR_LABELS = [
  { name: "red", labelColor: 1 },
  { name: "yellow", labelColor: 2 },
  { name: "green", labelColor: 3 },
  { name: "blue", labelColor: 4 },
  { name: "purple", labelColor: 5 },
  { name: "none", labelColor: "none" },
] as const;

export const COLOR_LABEL_NAMES = COLOR_LABELS.map((label) => label.name);

export const PROFILE_PRESET_GROUP = "lightroom-agent profiles";

const ADOBE_RAW_PROFILE_LOOKS = [
  {
    name: "Adobe Color",
    look_uuid: "B952C231111CD8E0ECCF14B86BAA7077",
    preset_uuid: "6C1F3E0A9B2D4E7F8A5C0B1D2E3F4A51",
  },
  {
    name: "Adobe Landscape",
    look_uuid: "6F9C877E84273F4E8271E6B91BEB36A1",
    preset_uuid: "6C1F3E0A9B2D4E7F8A5C0B1D2E3F4A52",
  },
] as const;

export const ADOBE_RAW_PROFILES = ADOBE_RAW_PROFILE_LOOKS.map((profile) => ({
  ...profile,
  preset_name: `lightroom-agent ${profile.name}`,
  camera_profile: "Adobe Standard",
  copyright: "© 2018 Adobe Systems, Inc.",
}));

export const ADOBE_RAW_PROFILE_NAMES = ADOBE_RAW_PROFILES.map((profile) => profile.name);
