import { useEffect, useState } from "react";
import { Check, Copy, KeyRound, LoaderCircle, Pencil, Trash2 } from "lucide-react";
import { api, type ClientToken, type ClientTokenList } from "../api";
import { useI18n } from "../i18n";
import { Alert, Button, Inline, Input, SettingRow, Text } from "./ui";
import "./DatabaseSettings.css";

/**
 * Where a profile hands its apps a way in: one token per app or device, each
 * under a name, so the one for a lost phone can be revoked without signing
 * the others out.
 *
 * A token is shown once, at the moment it is minted: what the server keeps is
 * a keyed hash of it, so this screen cannot show it again — and saying so
 * plainly is the difference between somebody copying it now and somebody
 * coming back for it later.
 */
export default function InvidiousAccess({ showToast }: { showToast: (message: string) => void }) {
  const { t } = useI18n();
  const [state, setState] = useState<ClientTokenList | null>(null);
  const [newName, setNewName] = useState("");
  const [minted, setMinted] = useState<{ name: string; token: string } | null>(null);
  const [editing, setEditing] = useState<number | null>(null);
  const [editName, setEditName] = useState("");
  const [busy, setBusy] = useState<number | "new" | null>(null);

  const load = () => api.clientTokens().then(setState).catch((error) => showToast(error.message));
  useEffect(() => { void load(); }, []);

  const run = async (key: number | "new", action: () => Promise<void>) => {
    setBusy(key);
    try {
      await action();
      await load();
    } catch (error: any) {
      showToast(error?.message ?? String(error));
    } finally {
      setBusy(null);
    }
  };

  const mint = () => run("new", async () => {
    const name = newName.trim();
    const { token } = await api.mintClientToken(name);
    setMinted({ name, token });
    setNewName("");
  });

  const rename = (token: ClientToken) => run(token.id, async () => {
    await api.renameClientToken(token.id, editName);
    setEditing(null);
  });

  const revoke = (token: ClientToken) => run(token.id, async () => {
    await api.revokeClientToken(token.id);
    showToast(t("clientTokenRevoked", { name: token.name || t("clientTokenUnnamed") }));
  });

  if (!state) return null;

  const when = (value: string | null) => value ? new Date(value.replace(" ", "T") + "Z").toLocaleString() : "—";
  const full = state.tokens.length >= state.limit;

  return (
    <>
      {!state.enabled && (
        <Alert variant="warning" title={t("clientAccessNotEnabled")}>
          {t("clientAccessNotEnabledHint")}
        </Alert>
      )}

      <SettingRow label={t("clientTokenNew")} description={full ? t("clientTokenLimit", { limit: state.limit }) : t("clientAccessTokenHint")}>
        <Inline>
          <Input
            value={newName}
            maxLength={80}
            placeholder={t("clientTokenNamePlaceholder")}
            aria-label={t("clientTokenNameLabel")}
            disabled={full}
            onChange={(event) => setNewName(event.target.value)}
            onKeyDown={(event) => { if (event.key === "Enter" && newName.trim() && !full) void mint(); }}
          />
          <Button onClick={() => void mint()} disabled={busy !== null || full || !newName.trim()}>
            {busy === "new" ? <LoaderCircle className="spin" aria-hidden="true" /> : <KeyRound aria-hidden="true" />}
            {t("clientTokenCreate")}
          </Button>
        </Inline>
      </SettingRow>

      {minted && (
        <Alert variant="info" title={`${t("clientAccessCopyNow")}: ${minted.name}`}>
          <Text>{t("clientTokenCopyNowHint")}</Text>
          <Inline>
            <code className="invidious-token">{minted.token}</code>
            <Button onClick={() => {
              void navigator.clipboard.writeText(minted.token);
              showToast(t("clientAccessCopied"));
            }}>
              <Copy aria-hidden="true" />
              {t("clientAccessCopy")}
            </Button>
          </Inline>
        </Alert>
      )}

      {state.tokens.length === 0 && <Text>{t("clientTokensEmpty")}</Text>}
      {state.tokens.map((token) => (
        <SettingRow
          key={token.id}
          label={editing === token.id ? (
            <Input
              value={editName}
              maxLength={80}
              autoFocus
              aria-label={t("clientTokenNameLabel")}
              onChange={(event) => setEditName(event.target.value)}
              onKeyDown={(event) => { if (event.key === "Enter") void rename(token); }}
            />
          ) : (
            <strong>{token.name || t("clientTokenUnnamed")}</strong>
          )}
          description={t("clientAccessTokenUsage", { created: when(token.created_at), used: when(token.last_used_at) })}
        >
          <Inline>
            {editing === token.id ? (
              <Button onClick={() => void rename(token)} disabled={busy === token.id}>
                <Check aria-hidden="true" />
                {t("devicesSave")}
              </Button>
            ) : (
              <Button variant="ghost" onClick={() => { setEditing(token.id); setEditName(token.name); }} disabled={busy === token.id}>
                <Pencil aria-hidden="true" />
                {t("devicesRename")}
              </Button>
            )}
            <Button variant="danger" onClick={() => void revoke(token)} disabled={busy === token.id}>
              <Trash2 aria-hidden="true" />
              {t("clientAccessRevoke")}
            </Button>
          </Inline>
        </SettingRow>
      ))}
    </>
  );
}
