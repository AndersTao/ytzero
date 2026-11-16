import { useCallback, useEffect, useState } from "react";
import { LoaderCircle } from "lucide-react";
import { ApiError, http } from "../../apiHttp";
import { useI18n } from "../../i18n";
import { Alert, Badge, Button, Inline, Input, SectionHeader, SettingRow, Switch, Text } from "../ui";

interface WebSubStatus {
  enabled: boolean;
  callbackBase: string;
  appUrl: string | null;
  effectiveBase: string | null;
  counts: { pending: number; active: number; failed: number; unsubscribing: number };
  followed: number;
  lastNotificationAt: string | null;
  lastError: string | null;
}

const loadStatus = () => http<WebSubStatus>("/websub");
const saveStatus = (enabled: boolean, callbackBase: string) =>
  http<WebSubStatus>("/websub", { method: "PUT", body: JSON.stringify({ enabled, callbackBase }) });

function isValidAddress(value: string): boolean {
  const trimmed = value.trim();
  if (!trimmed) return true;
  try {
    const url = new URL(trimmed);
    return (url.protocol === "https:" || url.protocol === "http:") && !url.search && !url.hash && !url.username && !url.password;
  } catch {
    return false;
  }
}

/**
 * Push updates over WebSub, configured per installation: whether it is on and
 * which public address Google's hub should call. Administrators only — the
 * server answers 403 to everyone else, and then this section is not shown.
 */
export default function WebSubSettings({ showToast }: { showToast: (message: string) => void }) {
  const { t } = useI18n();
  const [status, setStatus] = useState<WebSubStatus | null>(null);
  const [hidden, setHidden] = useState(false);
  const [enabled, setEnabled] = useState(false);
  const [address, setAddress] = useState("");
  const [saving, setSaving] = useState(false);

  const refresh = useCallback(async (resetForm = false) => {
    try {
      const next = await loadStatus();
      setStatus(next);
      if (resetForm) { setEnabled(next.enabled); setAddress(next.callbackBase); }
    } catch (error) {
      if (error instanceof ApiError && (error.status === 403 || error.status === 404)) setHidden(true);
    }
  }, []);

  useEffect(() => {
    void refresh(true);
    // Subscriptions are confirmed by the hub a little later; keep the counts current.
    const timer = window.setInterval(() => void refresh(false), 15_000);
    return () => window.clearInterval(timer);
  }, [refresh]);

  if (hidden) return null;
  if (!status) return <><SectionHeader title={t("webSubTitle")} level={3} /><LoaderCircle className="spin" size={16} /></>;

  const valid = isValidAddress(address);
  const dirty = enabled !== status.enabled || address.trim() !== status.callbackBase;
  const save = async () => {
    if (!valid) return;
    setSaving(true);
    try {
      const next = await saveStatus(enabled, address.trim());
      setStatus(next);
      setEnabled(next.enabled);
      setAddress(next.callbackBase);
      showToast(t("webSubSaved"));
    } catch (error: any) {
      showToast(error?.message ?? String(error));
    } finally {
      setSaving(false);
    }
  };

  return (
    <>
      <SectionHeader title={t("webSubTitle")} description={t("webSubHint")} level={3} />
      <SettingRow label={t("webSubEnable")}>
        <Switch checked={enabled} disabled={saving} ariaLabel={t("webSubEnable")} onCheckedChange={setEnabled} />
      </SettingRow>
      <SettingRow label={t("webSubAddress")}>
        <Input
          type="url"
          value={address}
          placeholder={status.appUrl ?? "https://ytzero.example.com"}
          disabled={saving}
          onChange={(event) => setAddress(event.target.value)}
          aria-invalid={!valid}
          style={{ minWidth: 280 }}
        />
      </SettingRow>
      <Text tone="secondary">{t("webSubAddressHint")}</Text>
      {!valid && <Alert variant="danger">{t("webSubInvalidAddress")}</Alert>}
      {!address.trim() && status.appUrl && <Text tone="secondary">{t("webSubAddressFromAppUrl")} {status.appUrl}</Text>}
      {enabled && !address.trim() && !status.appUrl && <Alert variant="warning">{t("webSubAddressMissing")}</Alert>}
      <Text tone="secondary">{t("webSubPrivacy")}</Text>
      <Inline justify="end">
        <Button variant="primary" onClick={() => void save()} disabled={!dirty || !valid || saving}>
          {saving && <LoaderCircle className="spin" size={15} />}{t("webSubSave")}
        </Button>
      </Inline>
      {status.enabled && (
        <SettingRow label={t("webSubStatus")}>
          <Inline gap={2}>
            <Badge variant="success">{status.counts.active} {t("webSubActive")}</Badge>
            {status.counts.pending > 0 && <Badge variant="warning">{status.counts.pending} {t("webSubPending")}</Badge>}
            {status.counts.failed > 0 && <Badge variant="danger">{status.counts.failed} {t("webSubFailed")}</Badge>}
            <Badge>{status.followed} {t("webSubFollowed")}</Badge>
          </Inline>
        </SettingRow>
      )}
      {status.enabled && (
        <Text tone="secondary">
          {t("webSubLastNotification")}: {status.lastNotificationAt ? new Date(status.lastNotificationAt).toLocaleString() : t("webSubNever")}
        </Text>
      )}
      {status.enabled && status.lastError && <Alert variant="warning">{t("webSubLastError")}: {status.lastError}</Alert>}
    </>
  );
}
