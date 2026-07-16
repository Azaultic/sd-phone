import { Newspaper, SquarePen } from 'lucide-react';

import { EmptyState } from '@/ui/EmptyState';
import { ListingCard } from '@/apps/_classifieds/ListingCard';
import { type Post } from './data';
import { t } from '@/i18n';

export function YourPostsTab({ posts, onCreate, onOpen, onDelete }: {
    posts: Post[];
    onCreate: () => void;
    onOpen: (post: Post) => void;
    onDelete: (post: Post) => void;
}) {
    const mine = posts.filter(p => p.mine);

    return (
        <div className="flex min-h-0 flex-1 flex-col">
            <div className="flex items-center justify-between px-5 pb-1 pt-1">
                <h1 className="text-[28px] font-bold tracking-tight text-black dark:text-white">{t('pages.yourPosts','Your Posts')}</h1>
                <button type="button" aria-label={t('pages.createPost','Create post')} onClick={onCreate} className="text-ios-blue active:opacity-60">
                    <SquarePen className="h-[24px] w-[24px]" strokeWidth={2} />
                </button>
            </div>

            <div className="min-h-0 flex-1 overflow-y-auto no-scrollbar px-4 pb-6 pt-1">
                {mine.length === 0 ? (
                    <EmptyState icon={Newspaper} title={t('pages.noPostsYet','No Posts Yet')}
                        subtitle={t('pages.noPostsMineSubtitle','Posts you create show up here. Tap the pencil to make one.')} />
                ) : (
                    <div className="flex flex-col gap-3">
                        {mine.map(p => <ListingCard key={p.id} item={p} subject="poster" onOpen={() => onOpen(p)} onDelete={() => onDelete(p)} />)}
                    </div>
                )}
            </div>
        </div>
    );
}
