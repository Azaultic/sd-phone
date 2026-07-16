import { useState } from 'react';

import { t } from '@/i18n';
import { AlertDialog } from '@/ui/AlertDialog';
import { fetchNui } from '@/core/nui';
import { ListGroup, ListRow } from '@/ui/ListGroup';
import { SubPage } from '../SettingsSubPage';

async function eraseAllContent(): Promise<void> {
    const keys: string[] = [];
    for (let i = 0; i < window.localStorage.length; i++) {
        const k = window.localStorage.key(i);
        if (k && k.startsWith('sd-phone:')) keys.push(k);
    }
    for (const k of keys) window.localStorage.removeItem(k);

    try { await fetchNui('sd-phone:close'); } catch { /* ignore */ }

    window.location.reload();
}

async function resetAllSettings(): Promise<void> {
    const PREFIXES = [
        'sd-phone:setup:',
        'sd-phone:mail:folderOrder',
        'sd-phone:mail:activeAccount',
    ];
    const keys: string[] = [];
    for (let i = 0; i < window.localStorage.length; i++) {
        const k = window.localStorage.key(i);
        if (k && PREFIXES.some(p => k.startsWith(p))) keys.push(k);
    }
    for (const k of keys) window.localStorage.removeItem(k);

    try { await fetchNui('sd-phone:close'); } catch { /* ignore */ }
    window.location.reload();
}

export function ResetPhonePage({ onBack }: { onBack: () => void }) {
    const [confirm, setConfirm] = useState<'reset' | 'erase' | null>(null);

    return (
        <>
            <SubPage title={t('settings.resetPhone', 'Reset Phone')} onBack={onBack}>
                <ListGroup footer={t('settings.resetAllFooter', 'Resetting all settings clears your setup, theme and folder layout but keeps health data and app history.')}>
                    <ListRow
                        label={t('settings.resetAllSettings', 'Reset All Settings')}
                        destructive
                        onPress={() => setConfirm('reset')}
                        divider
                    />
                    <ListRow label={t('settings.resetNetworkSettings', 'Reset Network Settings')}         destructive divider />
                    <ListRow label={t('settings.resetKeyboardDictionary', 'Reset Keyboard Dictionary')}      destructive divider />
                    <ListRow label={t('settings.resetHomeScreenLayout', 'Reset Home Screen Layout')}       destructive divider />
                    <ListRow label={t('settings.resetLocationPrivacy', 'Reset Location & Privacy')}       destructive />
                </ListGroup>

                <ListGroup footer={t('settings.eraseAllFooter', 'This will permanently erase all content and settings. This action cannot be undone.')}>
                    <ListRow
                        label={t('settings.eraseAllContent', 'Erase All Content and Settings')}
                        destructive
                        onPress={() => setConfirm('erase')}
                    />
                </ListGroup>
            </SubPage>

            {confirm === 'reset' && (
                <AlertDialog
                    title={t('settings.resetAllTitle', 'Reset All Settings?')}
                    message={t('settings.resetAllMessage', "Your phone setup, theme and layout preferences will reset. You'll be guided through setup again on next open.")}
                    confirmLabel={t('settings.resetConfirm', 'Reset')}
                    destructive
                    onCancel={() => setConfirm(null)}
                    onConfirm={() => { setConfirm(null); void resetAllSettings(); }}
                />
            )}

            {confirm === 'erase' && (
                <AlertDialog
                    title={t('settings.eraseAllTitle', 'Erase All Content and Settings?')}
                    message={t('settings.eraseAllMessage', 'Your phone will be wiped back to factory defaults. Server-side data (mail accounts, group memberships) is preserved — sign out / leave first if you want a complete reset.')}
                    confirmLabel={t('settings.eraseConfirm', 'Erase')}
                    destructive
                    onCancel={() => setConfirm(null)}
                    onConfirm={() => { setConfirm(null); void eraseAllContent(); }}
                />
            )}
        </>
    );
}
