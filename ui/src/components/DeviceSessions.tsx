import { useEffect, useState } from "react";
import { Check, LogOut, Pencil, Smartphone, Tablet, Tv } from "lucide-react";
import { api } from "../api";
import type { DeviceKind, DeviceSession } from "../devicePairingApi";
import { useI18n } from "../i18n";
import { Button, Inline, Input, SettingRow, Text } from "./ui";

export function DeviceKindIcon({ kind }: { kind: DeviceKind | undefined }) {
  if (kind === "phone") return <Smartphone aria-hidden="true" />;
  if (kind === "tablet") return <Tablet aria-hidden="true" />;
  return <Tv aria-hidden="true" />;
}

/**
 * Settings → Client access → Devices: the phones, tablets and TVs signed in
 * to this profile with a code, by the name given when they were approved,
 * with when each was last used. They stay signed in until they sign out, so
 * this is where one that is lost, sold or no longer wanted is signed out.
 */
export default function DeviceSessions({ showToast }: { showToast: (message: string) => void }) {
  const { t } = useI18n();
  const [devices, setDevices] = useState<DeviceSession[] | null>(null);
  const [editing, setEditing] = useState<string | null>(null);
  const [name, setName] = useState("");
  const [busy, setBusy] = useState<string | null>(null);

  const load = () => api.deviceSessions().then(({ devices }) => setDevices(devices)).catch((error) => showToast(error.message));
  useEffect(() => { void load(); }, []);

  const when = (value: string) => new Date(value.includes("T") ? value : `${value.replace(" ", "T")}Z`).toLocaleString();

  const save = async (device: DeviceSession) => {
    setBusy(device.id);
    try {
      await api.renameDeviceSession(device.id, name);
      setEditing(null);
      showToast(t("devicesRenamed"));
      await load();
    } catch (error: any) {
      showToast(error?.message ?? String(error));
    } finally {
      setBusy(null);
    }
  };

  const signOut = async (device: DeviceSession) => {
    setBusy(device.id);
    try {
      await api.signOutDeviceSession(device.id);
      showToast(t("devicesSignedOut", { name: device.name }));
      await load();
    } catch (error: any) {
      showToast(error?.message ?? String(error));
    } finally {
      setBusy(null);
    }
  };

  if (!devices) return null;

  return (
    <>
      <SettingRow label={t("devicesTitle")} description={t("devicesHint")}>
        {devices.length === 0 && <Text>{t("devicesEmpty")}</Text>}
      </SettingRow>
      {devices.map((device) => (
        <SettingRow
          key={device.id}
          label={(
            <Inline>
              <DeviceKindIcon kind={device.kind} />
              {editing === device.id ? (
                <Input
                  value={name}
                  maxLength={80}
                  autoFocus
                  aria-label={t("devicePairingNameLabel")}
                  onChange={(event) => setName(event.target.value)}
                  onKeyDown={(event) => { if (event.key === "Enter" && name.trim()) void save(device); }}
                />
              ) : (
                <strong>{device.name}</strong>
              )}
            </Inline>
          )}
          description={[
            device.last_seen ? t("devicesLastUsed", { when: when(device.last_seen) }) : t("devicesAdded", { when: when(device.created_at) }),
            device.current ? t("devicesThisDevice") : null,
          ].filter(Boolean).join(" · ")}
        >
          <Inline>
            {editing === device.id ? (
              <Button onClick={() => void save(device)} disabled={busy === device.id || !name.trim()}>
                <Check aria-hidden="true" />
                {t("devicesSave")}
              </Button>
            ) : (
              <Button variant="ghost" onClick={() => { setEditing(device.id); setName(device.name); }} disabled={busy === device.id}>
                <Pencil aria-hidden="true" />
                {t("devicesRename")}
              </Button>
            )}
            <Button variant="danger" onClick={() => void signOut(device)} disabled={busy === device.id}>
              <LogOut aria-hidden="true" />
              {t("devicesSignOut")}
            </Button>
          </Inline>
        </SettingRow>
      ))}
    </>
  );
}
