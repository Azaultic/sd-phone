import { useEffect, useRef, useState } from 'react';
import { RotateCw, Send } from 'lucide-react';

import { t } from '@/i18n';
import { AppBadge } from '@/shell/AppBadge';
import { type Post, type User } from '../data';
import type { LiveEntry, StoryGroup } from '../photogramApi';
import { StoriesRow } from '../stories/StoriesRow';
import { PostCard } from './PostCard';
import { VerifiedCheck } from '../ui';

export function Feed({ posts, me, stories, lives, hasOwnStory, onLike, onDoubleLike, onSave, onComment, onOpenStory, onOpenLive, onAddStory, onOpenDMs, onOpenProfile, onShare, onDelete, onRefresh, dmCount }: {
    posts:         Post[];
    me:            User | null;
    stories:       StoryGroup[];
    lives:         LiveEntry[];
    hasOwnStory:   boolean;
    onLike:        (id: string) => void;
    onDoubleLike:  (id: string) => void;
    onSave:        (id: string) => void;
    onComment:     (id: string) => void;
    onOpenStory:   (i: number) => void;
    onOpenLive:    (entry: LiveEntry) => void;
    onAddStory:    () => void;
    onOpenDMs:     () => void;
    onOpenProfile: (handle: string) => void;
    onShare:       (post: Post) => void;
    onDelete:      (post: Post) => void;
    onRefresh:     () => Promise<unknown>;
    dmCount?:      number;
}) {
    const scrollRef = useRef<HTMLDivElement>(null);
    const [refreshing, setRefreshing] = useState(false);
    const mounted = useRef(true);
    useEffect(() => () => { mounted.current = false; }, []);

    async function handleRefresh() {
        if (refreshing) return;
        setRefreshing(true);
        try { await Promise.all([onRefresh(), new Promise(r => setTimeout(r, 600))]); }
        finally { if (mounted.current) setRefreshing(false); }
    }
    return (
        <div className="flex min-h-0 flex-1 flex-col">
            <div className="flex shrink-0 items-center justify-between px-4 pb-0.5 pt-0.5">
                <div className="flex items-center gap-1.5">
                    <span className="text-[27px] font-bold italic tracking-tight text-black">Photogram</span>
                    <VerifiedCheck size={25} />
                </div>
                <div className="flex items-center gap-4">
                    <button type="button" aria-label={t('photogram.refresh', 'Refresh')} onClick={handleRefresh} disabled={refreshing} className="text-black active:opacity-50">
                        <RotateCw className={`h-[27px] w-[27px] ${refreshing ? 'animate-spin' : ''}`} strokeWidth={1.9} />
                    </button>
                    <button type="button" aria-label={t('photogram.directMessages', 'Direct messages')} onClick={onOpenDMs} className="relative text-black active:opacity-50">
                        <Send className="h-[30px] w-[30px]" strokeWidth={1.9} />
                        <AppBadge count={dmCount} dot />
                    </button>
                </div>
            </div>

            <div ref={scrollRef} className="min-h-0 flex-1 overflow-y-auto no-scrollbar">
                <StoriesRow stories={stories} lives={lives} me={me} hasOwnStory={hasOwnStory} onOpen={onOpenStory} onOpenLive={onOpenLive} onAddStory={onAddStory} />
                <div className="border-t border-black/[0.08]" />
                {posts.length === 0 ? (
                    <div className="flex flex-col items-center px-8 pt-20 text-center">
                        <div className="text-[20px] font-semibold text-black">{t('photogram.noPostsYet', 'No posts yet')}</div>
                        <div className="mt-1.5 text-[16px] leading-snug text-black/55">{t('photogram.noPostsDesc', 'Follow people or share your first post to fill your feed.')}</div>
                    </div>
                ) : posts.map((p, i) => (
                    <div key={p.id}>
                        {i > 0 && <div className="border-t border-black/[0.08]" />}
                        <PostCard
                            post={p}
                            onLike={() => onLike(p.id)}
                            onDoubleLike={() => onDoubleLike(p.id)}
                            onSave={() => onSave(p.id)}
                            onComment={() => onComment(p.id)}
                            onOpenProfile={onOpenProfile}
                            onShare={() => onShare(p)}
                            onDelete={me && me.handle === p.user.handle ? () => onDelete(p) : undefined}
                            scrollRoot={scrollRef}
                        />
                    </div>
                ))}
                <div className="h-2" />
            </div>
        </div>
    );
}
