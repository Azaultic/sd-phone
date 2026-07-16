import { X } from 'lucide-react';

import { t } from '@/i18n';
import { portalToPhoneScreen } from './portal';

export function ImageLightbox({ src, onClose, action }: {
    src:     string;
    onClose: () => void;
    action?: { label: string; onClick: () => void };
}) {
    const overlay = (
        <div
            className="absolute inset-0 z-[60] flex flex-col items-center justify-center px-4"
            style={{ background: 'rgba(0,0,0,0.92)', animation: 'ios-sheet-backdrop-in 0.2s ease-out' }}
            onClick={onClose}
        >
            <button
                type="button"
                onClick={e => { e.stopPropagation(); onClose(); }}
                aria-label={t('common.close', 'Close')}
                className="absolute right-4 top-14 flex h-9 w-9 items-center justify-center rounded-full text-white/85 active:opacity-60"
            >
                <X className="h-6 w-6" strokeWidth={2.2} />
            </button>
            <img
                src={src}
                alt=""
                className="max-h-[80%] max-w-full rounded-[8px] object-contain"
                onClick={e => e.stopPropagation()}
            />
            {action && (
                <button
                    type="button"
                    onClick={e => { e.stopPropagation(); action.onClick(); }}
                    className="mt-6 text-[15px] text-white/85 active:opacity-60"
                >
                    {action.label}
                </button>
            )}
        </div>
    );

    return portalToPhoneScreen(overlay);
}
