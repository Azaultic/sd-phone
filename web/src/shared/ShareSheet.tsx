import { useEffect, useState } from 'react';
import type { ReactNode } from 'react';
import { Smartphone } from 'lucide-react';

import { isFiveM } from '@/core/nui';
import { apiData } from '@/core/api';
import { t } from '@/i18n';
import { colorFor } from '@/lib/format';
import { Sheet } from '@/ui/Sheet';
import { InitialsAvatar } from '@/shared/ContactAvatar';


export interface ShareTarget { id: number; name: string }
type SendState = 'sending' | 'sent' | 'failed';

async function fetchNearby(): Promise<ShareTarget[]> {
    if (!isFiveM) return [{ id: 1, name: 'Breze' }, { id: 2, name: 'Loaf Scripts' }, { id: 3, name: 'Mike' }];
    return (await apiData<{ targets: ShareTarget[] }>('sd-phone:share:nearby'))?.targets ?? [];
}

export function ShareSheet({ onClose, onShare, children, top = '55%' }: {
    onClose:  () => void;
    onShare:  (target: ShareTarget) => Promise<boolean> | boolean;
    children?: ReactNode;
    top?:      string;
}) {
    const [targets, setTargets] = useState<ShareTarget[]>([]);
    const [loading, setLoading] = useState(true);
    const [state,   setState]   = useState<Record<number, SendState>>({});

    useEffect(() => {
        let alive = true;
        fetchNearby().then(t => { if (alive) { setTargets(t); setLoading(false); } }).catch(() => setLoading(false));
        return () => { alive = false; };
    }, []);

    async function send(t: ShareTarget) {
        if (state[t.id] === 'sending' || state[t.id] === 'sent') return;
        setState(s => ({ ...s, [t.id]: 'sending' }));
        const ok = await onShare(t);
        setState(s => ({ ...s, [t.id]: ok ? 'sent' : 'failed' }));
    }

    return (
        <Sheet onClose={onClose} top={top} durationMs={240} className="font-sf bg-[#ececec] dark:bg-[#1c1c1e]">
            {() => (
                <>
                <div className="px-4 pt-5">
                    {loading ? (
                        <p className="py-6 text-center text-[14px] text-ios-gray">{t('common.lookingForNearby', 'Looking for people nearby…')}</p>
                    ) : targets.length === 0 ? (
                        <p className="py-6 text-center text-[14px] text-ios-gray">{t('common.noOneNearby', 'No one nearby with their phone out.')}</p>
                    ) : (
                        <div className="flex gap-5 overflow-x-auto no-scrollbar pb-1">
                            {targets.map(target => {
                                const st = state[target.id];
                                return (
                                    <button key={target.id} type="button" onClick={() => void send(target)} className="flex w-[76px] shrink-0 flex-col items-center active:opacity-70">
                                        <span className="relative">
                                            <InitialsAvatar name={target.name} color={colorFor(target.name)} size={64} />
                                            <span className="absolute -bottom-0.5 -right-0.5 flex h-[24px] w-[24px] items-center justify-center rounded-full bg-black/10 ring-2 ring-[#ececec] dark:bg-white/15 dark:ring-[#1c1c1e]">
                                                <Smartphone className="h-[13px] w-[13px] text-black/60 dark:text-white/70" />
                                            </span>
                                        </span>
                                        <span className="mt-1.5 w-full truncate text-center text-[13px] text-black dark:text-white">{target.name}</span>
                                        <span className={`text-[12px] ${st === 'failed' ? 'text-ios-red' : 'text-ios-blue'}`}>
                                            {st === 'sent' ? t('common.sent', 'Sent') : st === 'sending' ? t('common.sending', 'Sending…') : st === 'failed' ? t('common.failed', 'Failed') : ' '}
                                        </span>
                                    </button>
                                );
                            })}
                        </div>
                    )}
                </div>

                {children && (
                    <>
                        <div className="mx-4 mt-5 h-px bg-black/10 dark:bg-white/10" />
                        <div className="flex flex-col gap-2.5 px-4 pt-5">{children}</div>
                    </>
                )}
                </>
            )}
        </Sheet>
    );
}

export function ShareAction({ icon, label, onClick }: { icon: ReactNode; label: string; onClick: () => void }) {
    return (
        <button type="button" onClick={onClick} className="flex w-full items-center justify-between rounded-[14px] bg-black/[0.05] px-5 py-5 text-left active:opacity-70 dark:bg-white/[0.06]">
            <span className="text-[18px] font-medium text-black dark:text-white">{label}</span>
            <span className="text-black/60 dark:text-white/70">{icon}</span>
        </button>
    );
}
