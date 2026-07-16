import { useState } from 'react';

import { t } from '@/i18n';
import { colorFor } from '@/lib/format';
import { InitialsAvatar } from '@/shared/ContactAvatar';

export interface AirShareRequest {
    id:       string;
    kind:     string;
    fromName: string;
}

export function AirShareCard({ request, onRespond }: {
    request:   AirShareRequest;
    onRespond: (accept: boolean) => void;
}) {
    const [exiting, setExiting] = useState(false);
    const kindText = request.kind === 'voice' ? t('common.aVoiceMemo', 'a voice memo')
        : request.kind === 'note' ? t('common.aNote', 'a note')
        : request.kind === 'pin' ? t('common.aMapPin', 'a map pin')
        : request.kind === 'music-track' ? t('common.aSong', 'a song')
        : request.kind === 'music-playlist' ? t('common.aPlaylist', 'a playlist')
        : t('common.aContact', 'a contact');

    function close(accept: boolean) {
        if (exiting) return;
        setExiting(true);
        window.setTimeout(() => onRespond(accept), 280);
    }

    const style = exiting
        ? { animation: 'notif-out 0.28s cubic-bezier(0.32,0,0.68,1) forwards' as const }
        : { animation: 'notif-in 0.5s cubic-bezier(0.16,1.16,0.3,1) both' as const };

    return (
        <div
            className="overflow-hidden rounded-[28px] bg-[#1c1c1e]/92 font-sf shadow-[0_14px_44px_rgba(0,0,0,0.45)] ring-1 ring-white/10 backdrop-blur-2xl"
            style={{ willChange: 'transform', ...style }}
        >
            <div className="flex items-start gap-3 px-5 pt-[44px]">
                <div className="min-w-0 flex-1">
                    <div className="text-[22px] font-bold text-white">AirShare</div>
                    <p className="mt-1 text-[16px] leading-snug text-white/55">
                        {t('common.wouldLikeToShare', '{name} would like to share {kind}', { name: request.fromName, kind: kindText })}
                    </p>
                </div>
                <InitialsAvatar name={request.fromName} color={colorFor(request.fromName)} size={78} />
            </div>

            <div className="flex gap-3 px-5 pb-5 pt-5">
                <button type="button" onClick={() => close(false)} className="flex-1 rounded-full bg-white/[0.14] py-3.5 text-[17px] font-semibold text-white active:opacity-70">
                    {t('common.decline', 'Decline')}
                </button>
                <button type="button" onClick={() => close(true)} className="flex-1 rounded-full bg-ios-blue py-3.5 text-[17px] font-semibold text-white active:opacity-80">
                    {t('common.accept', 'Accept')}
                </button>
            </div>
        </div>
    );
}
