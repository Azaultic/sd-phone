import { useEffect, useState } from 'react';

import { t } from '@/i18n';
import { portalToPhoneScreen } from '@/ui/portal';
import { ChangePasswordForm } from './AppAuth';
import type { AppAuthTheme } from './AppAuth';
import { accountsChangePassword, accountsListPasswords, accountsMe } from '@/core/accountsApi';

export function ChangePasswordPage({ app, appName, icon, theme, identity: identityProp, onClose }: {
    app:       string;
    appName:   string;
    icon?:     string;
    theme:     AppAuthTheme;
    identity?: string;
    onClose:   () => void;
}) {
    const [identity, setIdentity] = useState<string | null>(identityProp ?? null);
    const [savedPassword, setSavedPassword] = useState<string | null>(null);

    useEffect(() => {
        let alive = true;
        void (async () => {
            let id = identityProp ?? null;
            if (!id) {
                const { me } = await accountsMe(app);
                id = me?.username ?? null;
            }
            if (!alive) return;
            setIdentity(id);
            const entries = await accountsListPasswords();
            const entry = entries.find(e => e.app === app && (e.username === id || e.email === id));
            if (alive) setSavedPassword(entry?.password ?? null);
        })();
        return () => { alive = false; };
    }, [app, identityProp]);

    const form = (
        <div className="absolute inset-0 z-50">
            <ChangePasswordForm
                appName={appName}
                icon={icon}
                theme={theme}
                identity={identity ?? undefined}
                savedPassword={savedPassword}
                onSubmit={async (current, next) => {
                    const r = await accountsChangePassword(app, identity ?? '', current, next);
                    return r.ok ? null : (r.message ?? t('common.couldNotChangePassword', 'Could not change password'));
                }}
                onBack={onClose}
            />
        </div>
    );

    return portalToPhoneScreen(form);
}
