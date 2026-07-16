import { useRef } from 'react';
import { FolderPlus, Image as ImageIcon } from 'lucide-react';

import { t } from '@/i18n';
import { Sheet } from '@/ui/Sheet';
import type { Album } from '@/core/photosApi';

export function AlbumPickerSheet({ albums, count, onPick, onNewAlbum, onClose }: {
    albums:     Album[];
    count:      number;
    onPick:     (albumId: string) => void;
    onNewAlbum: () => void;
    onClose:    () => void;
}) {
    const pending = useRef<(() => void) | null>(null);

    function handleClose() {
        const action = pending.current;
        if (action) { action(); return; }
        onClose();
    }

    return (
        <Sheet onClose={handleClose} fit="content" grabber={false} className="bg-[#d4d4d4] pb-7 dark:bg-[#1c1c1e]">
            {({ close }) => {
                function runThenClose(action: () => void) { pending.current = action; close(); }
                return (
                    <>
                        <div className="sticky top-0 flex items-center justify-between border-b border-black/10 bg-[#d4d4d4]/95 px-4 py-3 backdrop-blur-xl dark:border-white/10 dark:bg-[#1c1c1e]/95">
                            <span className="text-[15px] font-semibold">
                                {t('photos.addPhotosToTitle', 'Add {count} {noun} to…', { count, noun: count === 1 ? t('photos.photoSingular', 'Photo') : t('photos.photoPlural', 'Photos') })}
                            </span>
                            <button type="button" onClick={close} className="text-[15px] font-medium text-ios-blue">
                                {t('photos.cancel', 'Cancel')}
                            </button>
                        </div>

                        <button
                            type="button"
                            onClick={() => runThenClose(onNewAlbum)}
                            className="flex w-full items-center gap-3 px-4 py-3 text-left active:bg-black/5 dark:active:bg-white/5"
                        >
                            <span className="flex h-10 w-10 items-center justify-center rounded-[8px] bg-ios-blue/15">
                                <FolderPlus className="h-5 w-5 text-ios-blue" />
                            </span>
                            <span className="text-[16px] font-medium text-ios-blue">{t('photos.newAlbumEllipsis', 'New Album…')}</span>
                        </button>

                        {albums.map(a => (
                            <button
                                key={a.id}
                                type="button"
                                onClick={() => runThenClose(() => onPick(a.id))}
                                className="flex w-full items-center gap-3 px-4 py-2.5 text-left active:bg-black/5 dark:active:bg-white/5"
                            >
                                <span className="flex h-10 w-10 items-center justify-center overflow-hidden rounded-[8px] bg-black/10 dark:bg-white/10">
                                    {a.cover
                                        ? <img src={a.cover} alt="" className="h-full w-full object-cover" draggable={false} />
                                        : <ImageIcon className="h-5 w-5 text-black/30 dark:text-white/30" />}
                                </span>
                                <span className="flex-1">
                                    <span className="block text-[16px] font-medium">{a.name}</span>
                                    <span className="block text-[13px] text-black/45 dark:text-white/45">{a.count}</span>
                                </span>
                            </button>
                        ))}

                        {albums.length === 0 && (
                            <p className="px-4 py-6 text-center text-[13px] text-black/45 dark:text-white/45">
                                {t('photos.noAlbumsYetCreate', 'No albums yet — create one above.')}
                            </p>
                        )}
                    </>
                );
            }}
        </Sheet>
    );
}
