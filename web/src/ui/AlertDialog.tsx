import { useEffect, useState } from 'react';

import { t } from '@/i18n';
import { DialogShell } from './DialogShell';
import { portalToPhoneScreen } from './portal';

interface Props {
    title:       string;
    message?:    string;
    confirmLabel?: string;
    cancelLabel?: string;
    destructive?: boolean;
    hideCancel?: boolean;
    forceDark?:  boolean;
    onCancel:    () => void;
    onConfirm:   () => void;
}

export function AlertDialog({
    title, message, confirmLabel = t('common.ok', 'OK'), cancelLabel = t('common.cancel', 'Cancel'),
    destructive = false, hideCancel = false, forceDark = false, onCancel, onConfirm,
}: Props) {
    const [exiting, setExiting] = useState(false);

    useEffect(() => {
        function onKey(e: KeyboardEvent) {
            if (e.key === 'Escape') { e.stopPropagation(); dismiss(onCancel); }
            else if (e.key === 'Enter') { e.stopPropagation(); dismiss(onConfirm); }
        }
        window.addEventListener('keydown', onKey, true);
        return () => window.removeEventListener('keydown', onKey, true);
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [onCancel, onConfirm]);

    function dismiss(after: () => void) {
        if (exiting) return;
        setExiting(true);
        window.setTimeout(after, 180);
    }

    return portalToPhoneScreen(
        <DialogShell
            title={title}
            message={message}
            exiting={exiting}
            forceDark={forceDark}
            zIndex={70}
            cancel={hideCancel ? undefined : { label: cancelLabel, onClick: () => dismiss(onCancel) }}
            confirm={{ label: confirmLabel, onClick: () => dismiss(onConfirm), destructive }}
        />,
    );
}
