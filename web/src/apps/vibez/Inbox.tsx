import { UserPlus } from 'lucide-react';

import { t } from '@/i18n';
import { ACCENT, INBOX } from './data';

const SB_H = 54;

export function Inbox() {
    return (
        <div className="flex h-full flex-col bg-black text-white">
            <div className="shrink-0" style={{ height: SB_H }} />

            <div className="shrink-0 px-4 pb-2">
                <h1 className="text-[22px] font-bold tracking-tight">{t('vibez.inbox', 'Inbox')}</h1>
            </div>

            <div className="min-h-0 flex-1 overflow-y-auto no-scrollbar pb-24">
                {INBOX.map(n => (
                    <div key={n.id} className="flex items-center gap-3 px-4 py-3 active:bg-white/5">
                        <div
                            className="flex h-11 w-11 shrink-0 items-center justify-center rounded-full text-[14px] font-bold text-white"
                            style={{ background: n.creator.color }}
                        >
                            {n.creator.initials}
                        </div>

                        <div className="min-w-0 flex-1">
                            <p className="text-[14px] leading-snug">
                                <span className="font-semibold">{n.creator.handle}</span>{' '}
                                <span className="text-white/80">{n.text}</span>
                            </p>
                            <span className="text-[12px] text-white/45">{n.time}</span>
                        </div>

                        {n.follow ? (
                            <button
                                type="button"
                                className="shrink-0 rounded-md px-4 py-1.5 text-[13px] font-semibold text-white active:opacity-80"
                                style={{ background: ACCENT }}
                            >
                                <span className="flex items-center gap-1">
                                    <UserPlus className="h-3.5 w-3.5" strokeWidth={2.6} />
                                    {t('vibez.follow', 'Follow')}
                                </span>
                            </button>
                        ) : n.thumb ? (
                            <img src={n.thumb} alt="" draggable={false} className="h-12 w-10 shrink-0 rounded object-cover" />
                        ) : null}
                    </div>
                ))}
            </div>
        </div>
    );
}
