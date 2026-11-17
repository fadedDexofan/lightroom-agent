export const MASK_TYPES = [
  { name: "subject", toolType: "aiSelection", subtype: "subject" },
  { name: "sky", toolType: "aiSelection", subtype: "sky" },
  { name: "background", toolType: "aiSelection", subtype: "background" },
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
  { name: "main", parameter: "local_Maincurve" },
  { name: "red", parameter: "local_Redcurve" },
  { name: "green", parameter: "local_Greencurve" },
  { name: "blue", parameter: "local_Bluecurve" },
] as const;

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
