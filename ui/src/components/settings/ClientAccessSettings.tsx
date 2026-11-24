import DeviceSessions from "../DeviceSessions";
import InvidiousAccess from "../InvidiousAccess";
import { useI18n } from "../../i18n";
import { SettingsSection } from "../ui";
import WebSubSettings from "./WebSubSettings";

/**
 * Settings → Client access, in three parts that have nothing else in common:
 * the devices signed in to this profile with a code, the token apps sign in
 * with, and — for an administrator — what applies to the whole server.
 */
export default function ClientAccessSettings({ showToast, isPrimary }: { showToast: (message: string) => void; isPrimary: boolean }) {
  const { t } = useI18n();
  return (
    <>
      <SettingsSection title={t("devicesTitle")} description={t("devicesHint")}>
        <DeviceSessions showToast={showToast} />
      </SettingsSection>
      <SettingsSection title={t("clientAppsTitle")} description={t("clientAppsHint")}>
        <InvidiousAccess showToast={showToast} />
      </SettingsSection>
      {isPrimary && (
        <SettingsSection title={t("serverWideTitle")} description={t("serverWideHint")}>
          <WebSubSettings showToast={showToast} />
        </SettingsSection>
      )}
    </>
  );
}
