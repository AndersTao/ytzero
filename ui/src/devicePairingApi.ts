import { http } from "./apiHttp";

export type DeviceKind = "tv" | "phone" | "tablet";

export interface DevicePairingVerification {
  user_code: string;
  device_name: string;
  /** Missing from a server before devices said what they are: a TV. */
  device_kind?: DeviceKind;
  profile_name: string;
  approved: boolean;
}

/** A phone, tablet or TV signed in to this profile with a code. */
export interface DeviceSession {
  id: string;
  name: string;
  kind: DeviceKind;
  created_at: string;
  last_seen: string | null;
  current: boolean;
}

export const devicePairingApi = {
  devicePairingVerification: (userCode: string) =>
    http<DevicePairingVerification>(`/auth/device/verification?user_code=${encodeURIComponent(userCode)}`),
  authorizeDevice: (userCode: string, deviceName?: string) =>
    http<{ ok: true }>("/auth/device/authorize", { method: "POST", body: JSON.stringify({ user_code: userCode, device_name: deviceName }) }),
  deviceSessions: () => http<{ devices: DeviceSession[] }>("/auth/devices"),
  renameDeviceSession: (id: string, name: string) =>
    http<{ ok: true }>(`/auth/devices/${encodeURIComponent(id)}`, { method: "PUT", body: JSON.stringify({ name }) }),
  signOutDeviceSession: (id: string) =>
    http<{ ok: true }>(`/auth/devices/${encodeURIComponent(id)}`, { method: "DELETE" }),
};
