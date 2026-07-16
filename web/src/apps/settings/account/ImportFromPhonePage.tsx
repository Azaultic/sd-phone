import { useState } from 'react';
import { Minus } from 'lucide-react';

import { t } from '@/i18n';
import { useIosPush } from '@/hooks/useIosPush';
import { NavBar } from '@/ui/NavBar';

interface ImportEntry { id: string; label: string }

const DEFAULT_IMPORTS: ImportEntry[] = [
    { id: 'i1', label: '(123) 456-7890' },
    { id: 'i2', label: '13144122' },
];

export function ImportFromPhonePage({ onBack }: { onBack: () => void }) {
    const { goBack, pageStyle } = useIosPush(onBack);
    const [editing, setEditing] = useState(false);
    const [imports, setImports] = useState<ImportEntry[]>(DEFAULT_IMPORTS);
    const [backed,  setBacked]  = useState(false);

    function remove(id: string) {
        setImports(prev => prev.filter(e => e.id !== id));
    }

    function createBackup() {
        setBacked(true);
        setTimeout(() => setBacked(false), 2000);
    }

    return (
        <div
            className="absolute inset-0 z-20 flex flex-col bg-[#d4d4d4] dark:bg-black"
            style={pageStyle}
        >
            <div className="h-11 shrink-0" aria-hidden />

            <NavBar
                backLabel={t('settings.settings', 'Settings')}
                onBack={goBack}
                title={t('settings.importFromPhone', 'Import from Phone')}
                hairline
                right={
                    <button
                        type="button"
                        onClick={() => setEditing(e => !e)}
                        className="text-[17px] active:opacity-60"
                    >
                        {editing ? t('settings.done', 'Done') : t('settings.edit', 'Edit')}
                    </button>
                }
            />

            <div className="flex-1 overflow-y-auto no-scrollbar">
                <div className="mt-6 flex flex-col gap-6 px-4 pb-10">

                    <div>
                        <p className="mb-2 px-1 text-[13px] uppercase tracking-wider text-ios-gray">
                            {t('settings.yourProfile', 'Your Profile')}
                        </p>
                        <div className="overflow-hidden rounded-[10px] bg-[#e5e5e5] dark:bg-[#1C1C1E]">
                            <button
                                type="button"
                                onClick={createBackup}
                                className="flex w-full items-center px-4 py-3 text-left active:bg-black/5 dark:active:bg-white/5"
                            >
                                <span className={`text-[17px] font-normal transition-colors ${backed ? 'text-ios-green' : 'text-black dark:text-white'}`}>
                                    {backed ? t('settings.backupCreated', 'Backup Created ✓') : t('settings.createBackup', 'Create Backup')}
                                </span>
                            </button>
                        </div>
                    </div>

                    <div>
                        <p className="mb-2 px-1 text-[13px] uppercase tracking-wider text-ios-gray">
                            {t('settings.imports', 'Imports')}
                        </p>
                        <div className="overflow-hidden rounded-[10px] bg-[#e5e5e5] dark:bg-[#1C1C1E]">
                            {imports.length === 0 && (
                                <div className="px-4 py-3">
                                    <span className="text-[15px] text-ios-gray">{t('settings.noImports', 'No imports')}</span>
                                </div>
                            )}
                            {imports.map((entry, i) => (
                                <div
                                    key={entry.id}
                                    className="relative flex items-center px-4 py-3"
                                >
                                    {editing && (
                                        <button
                                            type="button"
                                            onClick={() => remove(entry.id)}
                                            className="mr-3 flex h-[22px] w-[22px] shrink-0 items-center justify-center rounded-full bg-ios-red transition-transform active:scale-90"
                                        >
                                            <Minus className="h-[12px] w-[12px] text-white" strokeWidth={3} />
                                        </button>
                                    )}
                                    <span className="flex-1 text-[17px] font-normal text-black dark:text-white">
                                        {entry.label}
                                    </span>
                                    {i < imports.length - 1 && (
                                        <div
                                            className="pointer-events-none absolute bottom-0 right-0 bg-ios-gray4 dark:bg-[#38383A]"
                                            style={{ left: 0, height: '0.5px' }}
                                        />
                                    )}
                                </div>
                            ))}
                        </div>
                    </div>

                </div>
            </div>
        </div>
    );
}
