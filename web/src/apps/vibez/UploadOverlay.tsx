import { Camera, X } from 'lucide-react';

import { t } from '@/i18n';
import { ACCENT } from './data';

export function UploadOverlay({ onClose }: { onClose: () => void }) {
    return (
        <div className="absolute inset-0 z-30 flex flex-col items-center justify-center bg-black/95 px-8 text-center">
            <button
                type="button"
                aria-label={t('vibez.close', 'Close')}
                onClick={onClose}
                className="absolute right-5 top-[58px] flex h-9 w-9 items-center justify-center rounded-full bg-white/10 active:opacity-70"
            >
                <X className="h-5 w-5 text-white" strokeWidth={2.4} />
            </button>

            <div
                className="flex h-20 w-20 items-center justify-center rounded-full ring-4 ring-white/15"
                style={{ background: ACCENT }}
            >
                <Camera className="h-9 w-9 text-white" strokeWidth={2} />
            </div>

            <h2 className="mt-5 text-[18px] font-bold text-white">{t('vibez.recordAVibe', 'Record a Vibe')}</h2>
            <p className="mt-2 max-w-[260px] text-[14px] leading-relaxed text-white/60">
                {t('vibez.recordingUnavailable', 'Recording isn’t available in the demo. Hook up the camera on the Lua side to go live.')}
            </p>

            <button
                type="button"
                onClick={onClose}
                className="mt-7 rounded-full px-8 py-2.5 text-[15px] font-semibold text-white active:opacity-80"
                style={{ background: ACCENT }}
            >
                {t('vibez.gotIt', 'Got it')}
            </button>
        </div>
    );
}
