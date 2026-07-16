import { useState } from 'react';
import { Grid3x3, Heart, Lock, Play } from 'lucide-react';

import { ChangePasswordPage } from '@/shared/ChangePasswordPage';
import { t } from '@/i18n';
import { ACCENT, fmt, MY_POSTS, PROFILE } from './data';

const SB_H = 54;

export function Profile({ onSignOut }: { onSignOut: () => void }) {
    const [pwOpen, setPwOpen] = useState(false);

    return (
        <div className="flex h-full flex-col bg-black text-white">
            <div className="shrink-0" style={{ height: SB_H }} />

            <div className="min-h-0 flex-1 overflow-y-auto no-scrollbar pb-24">
                <div className="flex flex-col items-center px-4 pt-2">
                    <div
                        className="flex h-24 w-24 items-center justify-center rounded-full text-[30px] font-bold text-white"
                        style={{ background: PROFILE.color }}
                    >
                        {PROFILE.initials}
                    </div>
                    <div className="mt-3 text-[17px] font-semibold">@{PROFILE.handle}</div>

                    <div className="mt-4 flex items-center gap-7">
                        <Stat value={fmt(PROFILE.following)} label={t('vibez.followingCount', 'Following')} />
                        <Stat value={fmt(PROFILE.followers)} label={t('vibez.followers', 'Followers')} />
                        <Stat value={fmt(PROFILE.likes)} label={t('vibez.likes', 'Likes')} />
                    </div>

                    <button
                        type="button"
                        className="mt-4 rounded-md border border-white/20 px-8 py-1.5 text-[14px] font-semibold active:opacity-70"
                    >
                        {t('vibez.editProfile', 'Edit profile')}
                    </button>

                    <p className="mt-3 text-center text-[13px] text-white/80">{PROFILE.bio}</p>
                </div>

                <div className="mt-5 flex border-b border-white/10">
                    <div className="flex flex-1 items-center justify-center border-b-2 border-white pb-2.5">
                        <Grid3x3 className="h-5 w-5" strokeWidth={2.2} />
                    </div>
                    <div className="flex flex-1 items-center justify-center pb-2.5 text-white/40">
                        <Heart className="h-5 w-5" strokeWidth={2.2} />
                    </div>
                    <div className="flex flex-1 items-center justify-center pb-2.5 text-white/40">
                        <Lock className="h-5 w-5" strokeWidth={2.2} />
                    </div>
                </div>

                <div className="grid grid-cols-3 gap-0.5 pt-0.5">
                    {MY_POSTS.map((img, i) => (
                        <div key={i} className="relative aspect-[9/16] overflow-hidden bg-white/5">
                            <img src={img} alt="" draggable={false} className="h-full w-full object-cover" />
                            <div className="absolute bottom-1.5 left-1.5 flex items-center gap-1 text-white drop-shadow">
                                <Play className="h-3 w-3" fill="#fff" strokeWidth={0} />
                                <span className="text-[11px] font-semibold">{fmt(120 + i * 837)}</span>
                            </div>
                        </div>
                    ))}
                </div>

                <div className="px-4 pt-6">
                    <button
                        type="button"
                        onClick={() => setPwOpen(true)}
                        className="w-full rounded-md border border-white/20 py-2.5 text-[14px] font-semibold text-white/90 active:opacity-70"
                    >
                        {t('vibez.changePassword', 'Change Password')}
                    </button>
                    <button
                        type="button"
                        onClick={onSignOut}
                        className="mt-3 w-full rounded-md border border-white/20 py-2.5 text-[14px] font-semibold text-white/90 active:opacity-70"
                    >
                        {t('vibez.logOut', 'Log out')}
                    </button>
                </div>
            </div>

            {pwOpen && (
                <ChangePasswordPage
                    app="vibez"
                    appName="Vibez"
                    icon="vibez"
                    theme={{ accent: ACCENT, welcomeBg: '#000000', welcomeText: 'light' }}
                    onClose={() => setPwOpen(false)}
                />
            )}
        </div>
    );
}

function Stat({ value, label }: { value: string; label: string }) {
    return (
        <div className="flex flex-col items-center">
            <span className="text-[17px] font-bold">{value}</span>
            <span className="text-[12px] text-white/55">{label}</span>
        </div>
    );
}
