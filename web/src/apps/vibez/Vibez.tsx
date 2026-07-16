import { useEffect } from 'react';
import { Home, Inbox as InboxIcon, Plus, Search, User } from 'lucide-react';

import { useTheme } from '@/stores/themeStore';
import { useSessionState } from '@/hooks/useSessionState';
import { readJson, writeJson } from '@/lib/storage';
import { useAppAuth } from '@/hooks/useAppAuth';
import { AppAuth } from '@/shared/AppAuth';
import { MAIL_DOMAIN, accountsConfirmReset, accountsLogin, accountsLogout, accountsMe, accountsRegister, accountsRequestReset, accountsSavePassword, accountsSuggestCode } from '@/core/accountsApi';
import { t } from '@/i18n';
import { ACCENT, POSTS, type VPost } from './data';
import { Feed } from './Feed';
import { Discover } from './Discover';
import { Inbox } from './Inbox';
import { Profile } from './Profile';
import { UploadOverlay } from './UploadOverlay';

type Tab = 'home' | 'discover' | 'inbox' | 'profile';

const LS_KEY = 'sd-phone:vibez:v1';

interface Saved { liked?: string[]; saved?: string[] }

function loadSaved(): Saved {
    return readJson<Saved>(LS_KEY) ?? {};
}

function persist(posts: VPost[]) {
    const liked = posts.filter(p => p.liked).map(p => p.id);
    const saved = posts.filter(p => p.saved).map(p => p.id);
    writeJson(LS_KEY, { liked, saved });
}

export function Vibez({ onClose: _onClose }: { onClose: () => void }) {
    const { authed, setAuthed, authChecked, justAuthed, setJustAuthed, myNumber, myEmail, savedLogin } = useAppAuth('vibez',
        () => accountsMe('vibez').then(s => s.loggedIn));

    const { setStatusLightOverride } = useTheme('setStatusLightOverride');
    useEffect(() => {
        if (!authed) return;
        setStatusLightOverride(true);
        return () => setStatusLightOverride(null);
    }, [authed, setStatusLightOverride]);

    const [tab,    setTab]    = useSessionState<Tab>('vibez:tab', 'home');
    const [upload, setUpload] = useSessionState('vibez:upload', false);
    const [posts,  setPosts]  = useSessionState<VPost[]>('vibez:posts', () => {
        const s = loadSaved();
        const likedSet = new Set(s.liked ?? []);
        const savedSet = new Set(s.saved ?? []);
        return POSTS.map(p => {
            const wasLiked = likedSet.has(p.id);
            const liked = wasLiked || !!p.liked;
            const likes = wasLiked && !p.liked ? p.likes + 1 : p.likes;
            return { ...p, liked, likes, saved: savedSet.has(p.id) || !!p.saved };
        });
    });

    function toggleLike(id: string) {
        setPosts(prev => {
            const next = prev.map(p => p.id === id
                ? { ...p, liked: !p.liked, likes: p.likes + (p.liked ? -1 : 1) }
                : p);
            persist(next);
            return next;
        });
    }
    function likeOn(id: string) {
        setPosts(prev => {
            const next = prev.map(p => p.id === id && !p.liked
                ? { ...p, liked: true, likes: p.likes + 1 }
                : p);
            persist(next);
            return next;
        });
    }
    function toggleSave(id: string) {
        setPosts(prev => {
            const next = prev.map(p => p.id === id ? { ...p, saved: !p.saved } : p);
            persist(next);
            return next;
        });
    }

    if (!authChecked) {
        return <div className="absolute inset-0 z-10 bg-black" />;
    }
    if (!authed) {
        return (
            <AppAuth
                appName="vibez"
                tagline={t('vibez.tagline', 'Real people. Real moments.')}
                icon="vibez"
                theme={{ accent: ACCENT, welcomeBg: '#000000', welcomeText: 'light' }}
                myNumber={myNumber}
                myEmail={myEmail}
                savedLogin={savedLogin}
                fields={[
                    { key: 'username', label: t('vibez.username', 'Username') },
                    { key: 'name',     label: t('vibez.name', 'Name') },
                    { key: 'password', label: t('vibez.password', 'Password'), type: 'password' },
                    { key: 'email',    label: t('vibez.email', 'Email'), suffix: `@${MAIL_DOMAIN}`, createOnly: true },
                    { key: 'phone',    label: t('vibez.phone', 'Phone'), type: 'tel',   createOnly: true },
                ]}
                onSubmit={(mode, vals) => (mode === 'create' ? accountsRegister('vibez', vals) : accountsLogin('vibez', vals))}
                onAuthed={() => { setAuthed(true); setJustAuthed(true); }}
                onRequestReset={(id) => accountsRequestReset('vibez', id)}
                onConfirmReset={(id, code, pw) => accountsConfirmReset('vibez', id, code, pw)}
                onSuggestCode={(id) => accountsSuggestCode('vibez', id)}
                onSaveCredentials={(vals) => accountsSavePassword('vibez', vals)}
            />
        );
    }

    return (
        <div className={`absolute inset-0 z-10 flex flex-col select-none overflow-hidden bg-black text-white ${justAuthed ? 'animate-swipe-in-left' : ''}`}>
            <div className="min-h-0 flex-1 overflow-hidden">
                {tab === 'home' && (
                    <Feed posts={posts} onToggleLike={toggleLike} onLikeOn={likeOn} onToggleSave={toggleSave} />
                )}
                {tab === 'discover' && <Discover />}
                {tab === 'inbox'    && <Inbox />}
                {tab === 'profile'  && <Profile onSignOut={() => { void accountsLogout('vibez'); setAuthed(false); }} />}
            </div>

            <nav className="shrink-0 bg-black px-2 pb-[22px] pt-2">
                <div className="flex items-end justify-around">
                    <NavItem label={t('vibez.home', 'Home')} active={tab === 'home'} onClick={() => setTab('home')}>
                        <Home className="h-[26px] w-[26px]" strokeWidth={tab === 'home' ? 2.4 : 2} fill={tab === 'home' ? 'currentColor' : 'none'} />
                    </NavItem>
                    <NavItem label={t('vibez.discover', 'Discover')} active={tab === 'discover'} onClick={() => setTab('discover')}>
                        <Search className="h-[25px] w-[25px]" strokeWidth={tab === 'discover' ? 2.6 : 2} />
                    </NavItem>

                    <button
                        type="button"
                        aria-label={t('vibez.upload', 'Upload')}
                        onClick={() => setUpload(true)}
                        className="relative flex h-[30px] w-[46px] items-center justify-center active:scale-95 transition-transform"
                    >
                        <span className="absolute left-0 h-full w-[38px] rounded-[9px] bg-[#25F4EE]" />
                        <span className="absolute right-0 h-full w-[38px] rounded-[9px] bg-[#FE2C55]" />
                        <span className="relative flex h-full w-[40px] items-center justify-center rounded-[9px] bg-white">
                            <Plus className="h-5 w-5 text-black" strokeWidth={3} />
                        </span>
                    </button>

                    <NavItem label={t('vibez.inbox', 'Inbox')} active={tab === 'inbox'} onClick={() => setTab('inbox')}>
                        <InboxIcon className="h-[25px] w-[25px]" strokeWidth={tab === 'inbox' ? 2.6 : 2} />
                    </NavItem>
                    <NavItem label={t('vibez.profile', 'Profile')} active={tab === 'profile'} onClick={() => setTab('profile')}>
                        <User className="h-[25px] w-[25px]" strokeWidth={tab === 'profile' ? 2.6 : 2} fill={tab === 'profile' ? 'currentColor' : 'none'} />
                    </NavItem>
                </div>
            </nav>

            {upload && <UploadOverlay onClose={() => setUpload(false)} />}
        </div>
    );
}

function NavItem({ label, active, onClick, children }: {
    label:    string;
    active:   boolean;
    onClick:  () => void;
    children: React.ReactNode;
}) {
    return (
        <button
            type="button"
            aria-label={label}
            onClick={onClick}
            className="flex w-14 flex-col items-center gap-0.5 active:opacity-70"
            style={{ color: active ? ACCENT : '#fff' }}
        >
            {children}
            <span className="text-[10px] font-medium leading-none">{label}</span>
        </button>
    );
}
