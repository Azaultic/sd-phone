import { useRef, useState } from 'react';
import {
    BadgeCheck, Bookmark, Heart, MessageCircle, MoreHorizontal, Music2, Plus, Share2,
} from 'lucide-react';

import { useSessionState } from '@/hooks/useSessionState';
import { t } from '@/i18n';
import { ACCENT, fmt, type VPost } from './data';

const SB_H = 54;

type FeedTab = 'following' | 'foryou';

interface Pop { id: number; x: number; y: number }

export function Feed({ posts, onToggleLike, onLikeOn, onToggleSave }: {
    posts:        VPost[];
    onToggleLike: (id: string) => void;
    onLikeOn:     (id: string) => void;
    onToggleSave: (id: string) => void;
}) {
    const [feedTab, setFeedTab] = useSessionState<FeedTab>('vibez:feedTab', 'foryou');
    const [active, setActive] = useState(0);

    function handleScroll(e: React.UIEvent<HTMLDivElement>) {
        const el = e.currentTarget;
        const idx = Math.round(el.scrollTop / Math.max(1, el.clientHeight));
        setActive(prev => (prev === idx ? prev : idx));
    }

    return (
        <div className="relative h-full w-full">
            <style>{`
                @keyframes vibez-disc-spin { from { transform: rotate(0deg); } to { transform: rotate(360deg); } }
                @keyframes vibez-heart-pop {
                    0%   { transform: translate(-50%,-50%) scale(0)   rotate(-18deg); opacity: 0; }
                    18%  { transform: translate(-50%,-50%) scale(1.25) rotate(-12deg); opacity: 1; }
                    42%  { transform: translate(-50%,-50%) scale(0.95) rotate(-12deg); opacity: 1; }
                    70%  { transform: translate(-50%,-58%) scale(1)    rotate(-10deg); opacity: 1; }
                    100% { transform: translate(-50%,-92%) scale(1.1)  rotate(-8deg);  opacity: 0; }
                }
            `}</style>

            <div
                className="h-full w-full overflow-y-auto no-scrollbar"
                style={{ scrollSnapType: 'y mandatory' }}
                onScroll={handleScroll}
            >
                {posts.map((p, i) => (
                    Math.abs(i - active) <= 1
                        ? (
                            <PostFrame
                                key={p.id}
                                post={p}
                                onToggleLike={() => onToggleLike(p.id)}
                                onLikeOn={() => onLikeOn(p.id)}
                                onToggleSave={() => onToggleSave(p.id)}
                            />
                        )
                        : (
                            <section
                                key={p.id}
                                className="relative h-full w-full overflow-hidden bg-black"
                                style={{ scrollSnapStop: 'always', scrollSnapAlign: 'start' }}
                            />
                        )
                ))}
            </div>

            <div
                className="pointer-events-none absolute inset-x-0 flex items-center justify-center gap-5"
                style={{ top: SB_H - 4 }}
            >
                <TopTab active={feedTab === 'following'} onClick={() => setFeedTab('following')}>{t('vibez.following', 'Following')}</TopTab>
                <span className="h-3.5 w-px bg-white/30" aria-hidden />
                <TopTab active={feedTab === 'foryou'} onClick={() => setFeedTab('foryou')}>{t('vibez.forYou', 'For You')}</TopTab>
            </div>
        </div>
    );
}

function TopTab({ active, onClick, children }: { active: boolean; onClick: () => void; children: React.ReactNode }) {
    return (
        <button
            type="button"
            onClick={onClick}
            className="pointer-events-auto relative flex flex-col items-center active:opacity-70"
        >
            <span
                className={active ? 'text-[16px] font-bold text-white' : 'text-[16px] font-semibold text-white/55'}
                style={active ? { textShadow: '0 1px 6px rgba(0,0,0,0.5)' } : undefined}
            >
                {children}
            </span>
            {active && <span className="absolute -bottom-1.5 h-[3px] w-6 rounded-full bg-white" />}
        </button>
    );
}

function PostFrame({ post, onToggleLike, onLikeOn, onToggleSave }: {
    post:         VPost;
    onToggleLike: () => void;
    onLikeOn:     () => void;
    onToggleSave: () => void;
}) {
    const [pops, setPops] = useState<Pop[]>([]);
    const lastTap = useRef(0);
    const popId   = useRef(0);

    function handleTap(e: React.MouseEvent<HTMLDivElement>) {
        const now = Date.now();
        if (now - lastTap.current < 280) {
            const rect = e.currentTarget.getBoundingClientRect();
            const x = e.clientX - rect.left;
            const y = e.clientY - rect.top;
            const id = ++popId.current;
            setPops(prev => [...prev, { id, x, y }]);
            window.setTimeout(() => setPops(prev => prev.filter(p => p.id !== id)), 750);
            onLikeOn();
            lastTap.current = 0;
        } else {
            lastTap.current = now;
        }
    }

    return (
        <section
            className="relative h-full w-full overflow-hidden bg-black"
            style={{ scrollSnapStop: 'always', scrollSnapAlign: 'start' }}
        >
            <div className="absolute inset-0" onClick={handleTap}>
                <img
                    src={post.video}
                    alt=""
                    draggable={false}
                    className="h-full w-full object-cover"
                />
                <div className="pointer-events-none absolute inset-x-0 top-0 h-32 bg-gradient-to-b from-black/45 to-transparent" />
                <div className="pointer-events-none absolute inset-x-0 bottom-0 h-72 bg-gradient-to-t from-black/70 via-black/25 to-transparent" />

                {pops.map(p => (
                    <Heart
                        key={p.id}
                        className="pointer-events-none absolute h-24 w-24 drop-shadow-lg"
                        style={{
                            left: p.x, top: p.y,
                            color: ACCENT, fill: ACCENT,
                            animation: 'vibez-heart-pop 0.75s ease-out forwards',
                        }}
                    />
                ))}
            </div>

            <div className="absolute bottom-[150px] right-2.5 flex flex-col items-center gap-[18px]">
                <div className="relative mb-1">
                    <div
                        className="flex h-12 w-12 items-center justify-center rounded-full text-[15px] font-bold text-white ring-2 ring-white"
                        style={{ background: post.creator.color }}
                    >
                        {post.creator.initials}
                    </div>
                    <span
                        className="absolute -bottom-2 left-1/2 flex h-5 w-5 -translate-x-1/2 items-center justify-center rounded-full text-white ring-2 ring-black/0"
                        style={{ background: ACCENT }}
                    >
                        <Plus className="h-3.5 w-3.5" strokeWidth={3} />
                    </span>
                </div>

                <RailAction
                    label={t('vibez.like', 'Like')}
                    count={fmt(post.likes)}
                    onClick={onToggleLike}
                >
                    <Heart
                        className="h-[34px] w-[34px] drop-shadow"
                        style={post.liked ? { color: ACCENT, fill: ACCENT } : { color: '#fff' }}
                        strokeWidth={post.liked ? 0 : 1.8}
                    />
                </RailAction>

                <RailAction label={t('vibez.comments', 'Comments')} count={fmt(post.comments)} onClick={() => { /* demo */ }}>
                    <MessageCircle className="h-[33px] w-[33px] text-white drop-shadow" fill="#fff" strokeWidth={0} />
                </RailAction>

                <RailAction label={t('vibez.save', 'Save')} count={fmt(post.saves)} onClick={onToggleSave}>
                    <Bookmark
                        className="h-[31px] w-[31px] drop-shadow"
                        style={post.saved ? { color: '#FACC15', fill: '#FACC15' } : { color: '#fff' }}
                        strokeWidth={post.saved ? 0 : 1.9}
                    />
                </RailAction>

                <RailAction label={t('vibez.share', 'Share')} onClick={() => { /* demo */ }}>
                    <Share2 className="h-[30px] w-[30px] text-white drop-shadow" strokeWidth={1.9} />
                </RailAction>

                <button type="button" aria-label={t('vibez.more', 'More')} className="active:opacity-60">
                    <MoreHorizontal className="h-7 w-7 text-white drop-shadow" strokeWidth={2.2} />
                </button>

                <div
                    className="mt-1 flex h-12 w-12 items-center justify-center rounded-full ring-[5px] ring-black/30"
                    style={{
                        background: `radial-gradient(circle at 50% 50%, ${post.creator.color} 0 30%, #1a1a1a 31% 100%)`,
                        animation: 'vibez-disc-spin 4s linear infinite',
                    }}
                >
                    <div className="flex h-5 w-5 items-center justify-center rounded-full bg-black/70">
                        <Music2 className="h-3 w-3 text-white" strokeWidth={2.4} />
                    </div>
                </div>
            </div>

            <div className="absolute bottom-[120px] left-3.5 right-20">
                <div className="flex items-center gap-1.5">
                    <span className="text-[16px] font-bold text-white drop-shadow">@{post.creator.handle}</span>
                    {post.creator.verified && (
                        <BadgeCheck className="h-[15px] w-[15px]" style={{ color: '#1D9BF0', fill: '#1D9BF0' }} strokeWidth={0} />
                    )}
                    <span className="text-[13px] text-white/70">· {post.time}</span>
                </div>
                <div className="mt-1.5 text-[14px] leading-snug text-white drop-shadow">{post.caption}</div>
                <div className="mt-2 flex items-center gap-1.5 text-[13px] text-white/90">
                    <Music2 className="h-3.5 w-3.5 shrink-0" strokeWidth={2.2} />
                    <span className="truncate">{post.sound}</span>
                </div>
            </div>
        </section>
    );
}

function RailAction({ label, count, onClick, children }: {
    label:    string;
    count?:   string;
    onClick:  () => void;
    children: React.ReactNode;
}) {
    return (
        <button type="button" aria-label={label} onClick={onClick} className="flex flex-col items-center gap-1 active:scale-90 transition-transform">
            {children}
            {count !== undefined && (
                <span className="text-[12px] font-semibold text-white drop-shadow">{count}</span>
            )}
        </button>
    );
}
