import { useMemo } from 'react';
import { ChevronLeft, SquarePen } from 'lucide-react';

import { t } from '@/i18n';
import { useIosPush } from '@/hooks/useIosPush';
import { useSessionState } from '@/hooks/useSessionState';
import { SearchBar } from '@/ui/SearchBar';
import { getFolders, formatMailTime, inFolder, previewBody } from './data';
import type { Folder, MailMessage } from './data';

interface Props {
    folder:    Folder;
    accountId?:  string;
    accountName?: string;
    messages:  MailMessage[];
    onBack:    () => void;
    onOpen:    (id: string) => void;
    onCompose: () => void;
}

export function MailList({ folder, accountId, accountName, messages, onBack, onOpen, onCompose }: Props) {
    const { goBack, pageStyle } = useIosPush(onBack);
    const [query, setQuery] = useSessionState('mail:listQuery', '');

    const folderLabel = getFolders().find(f => f.id === folder)?.label ?? t('mail.mailbox', 'Mailbox');
    const label = accountName ?? folderLabel;

    const visible = useMemo(() => {
        const list = inFolder(messages, folder, accountId);
        const sorted = [...list].sort((a, b) => b.sentAt.localeCompare(a.sentAt));
        const q = query.trim().toLowerCase();
        if (!q) return sorted;
        return sorted.filter(m =>
            m.subject.toLowerCase().includes(q)
            || m.from.name.toLowerCase().includes(q)
            || previewBody(m.body).toLowerCase().includes(q),
        );
    }, [messages, folder, accountId, query]);

    return (
        <div
            className="absolute inset-0 z-20 flex flex-col bg-[#d4d4d4] dark:bg-black text-black dark:text-white"
            style={pageStyle}
        >
            <div className="h-[54px] shrink-0" aria-hidden />

            <div className="flex items-center px-2 pb-0.5">
                <button
                    type="button"
                    onClick={goBack}
                    className="flex items-center gap-0.5 text-ios-blue active:opacity-60"
                >
                    <ChevronLeft className="h-[22px] w-[22px]" strokeWidth={2.5} />
                    <span className="text-[17px]">{t('mail.mailboxes', 'Mailboxes')}</span>
                </button>
                <button
                    type="button"
                    onClick={onCompose}
                    className="ml-auto pr-3 text-ios-blue active:opacity-60"
                >
                    <SquarePen className="h-[22px] w-[22px]" strokeWidth={2} />
                </button>
            </div>

            <div className="px-5 pb-2 pt-0.5 text-[34px] font-bold tracking-tight">
                {label}
            </div>

            <SearchBar value={query} onChange={setQuery} className="mx-4 mb-3" />

            <div className="flex-1 overflow-y-auto no-scrollbar px-4 pb-10">
                {visible.length === 0 ? (
                    <div className="flex items-center justify-center py-16 text-[15px] text-black/40 dark:text-white/40">
                        {t('mail.noMessages', 'No Messages')}
                    </div>
                ) : (
                    <div className="overflow-hidden rounded-[10px] bg-[#e5e5e5] dark:bg-[#1C1C1E]">
                        {visible.map((m, i) => (
                            <div key={m.id}>
                                <MailRow msg={m} onOpen={onOpen} />
                                {i < visible.length - 1 && (
                                    <div
                                        className="pointer-events-none bg-black/[0.14] dark:bg-white/[0.12]"
                                        style={{ height: '0.5px' }}
                                    />
                                )}
                            </div>
                        ))}
                    </div>
                )}
            </div>
        </div>
    );
}

function MailRow({ msg, onOpen }: { msg: MailMessage; onOpen: (id: string) => void }) {
    return (
        <button
            type="button"
            onClick={() => onOpen(msg.id)}
            className="relative flex w-full items-start gap-2.5 px-4 py-3.5 text-left active:bg-black/5 dark:active:bg-white/5"
        >
            <span className="mt-[9px] flex h-[11px] w-[11px] shrink-0 items-center justify-center">
                {!msg.read && (
                    <span className="block h-[11px] w-[11px] rounded-full bg-ios-blue" />
                )}
            </span>

            <div className="min-w-0 flex-1">
                <div className="flex items-baseline justify-between gap-2">
                    <span className="truncate text-[19px] font-semibold">{msg.from.name}</span>
                    <span className="shrink-0 text-[14px] text-ios-gray">
                        {formatMailTime(msg.sentAt)}
                    </span>
                </div>
                <div className="mt-0.5 truncate text-[17px]">{msg.subject || t('mail.noSubject', '(No Subject)')}</div>
                <div className="mt-0.5 line-clamp-2 text-[15px] leading-snug text-black/[0.82] dark:text-white/[0.82]">
                    {previewBody(msg.body)}
                </div>
            </div>
        </button>
    );
}
