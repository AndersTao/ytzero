/*
 * Devices signed in with a code (phones, tablets, TVs): naming one while
 * approving it, and the list under Settings → Client access.
 */
const en = {
  devicePairingNameLabel: "Name",
  devicePairingNameHint: "So you can tell it apart later under Settings → Client access → Devices.",
  devicePairingKindTv: "TV",
  devicePairingKindPhone: "Phone",
  devicePairingKindTablet: "Tablet",
  devicesTitle: "Devices",
  devicesHint: "Phones, tablets and TVs signed in to this profile with a code. They stay signed in as long as they are used (one unused for half a year is signed out by itself), or until you sign them out here.",
  devicesEmpty: "No device is signed in with a code yet.",
  devicesLastUsed: "Last used {when}",
  devicesAdded: "Added {when}",
  devicesThisDevice: "This device",
  devicesSignOut: "Sign out",
  devicesSignedOut: "{name} is signed out",
  devicesRename: "Rename",
  devicesSave: "Save",
  devicesRenamed: "Name saved",
};

type DeviceMessages = typeof en;

const da: DeviceMessages = {
  devicePairingNameLabel: "Navn",
  devicePairingNameHint: "Så du kan kende den igen under Indstillinger → Klientadgang → Enheder.",
  devicePairingKindTv: "Tv",
  devicePairingKindPhone: "Telefon",
  devicePairingKindTablet: "Tablet",
  devicesTitle: "Enheder",
  devicesHint: "Telefoner, tablets og tv'er, der er logget ind på denne profil med en kode. De forbliver logget ind, så længe de bliver brugt (en, der ikke er brugt i et halvt år, logges selv ud), eller til du logger dem ud her.",
  devicesEmpty: "Ingen enheder er logget ind med en kode endnu.",
  devicesLastUsed: "Senest brugt {when}",
  devicesAdded: "Tilføjet {when}",
  devicesThisDevice: "Denne enhed",
  devicesSignOut: "Log ud",
  devicesSignedOut: "{name} er logget ud",
  devicesRename: "Omdøb",
  devicesSave: "Gem",
  devicesRenamed: "Navnet er gemt",
};

/*
 * The approval page was written for TVs. It now signs phones and tablets in
 * too, and such a device stays signed in until it signs out: the wording that
 * said TV, or 30 days, says device and that instead. English is reworded
 * here and Danish in da.ts; the other languages keep their own (TV) wording.
 */
const pairingEn = {
  tvPairingTitle: "Approve a device",
  tvPairingDescription: "Enter the code YT Zero shows on the device, then approve access to this profile.",
  tvPairingConfirmDescription: "Check the device and profile, give the device a name, then allow access.",
  tvPairingCodeLabel: "Code",
  tvPairingApprove: "Allow access",
  tvPairingApprovedTitle: "Device approved",
  tvPairingApprovedDescription: "You can go back to the device. It signs in by itself.",
  tvPairingSecurityDescription: "Only approve a device you recognize. It keeps access to the profile shown above as long as it is used, until it signs out or you sign it out under Settings → Client access.",
};

// The other languages show English for the new lines until someone translates them.
export const deviceMessages = {
  en: { ...en, ...pairingEn },
  da,
  de: en, pl: en, fr: en, es: en, "pt-BR": en, ru: en, ja: en, hu: en,
} as const;
