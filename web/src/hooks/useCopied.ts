import { useCallback, useEffect, useRef, useState } from 'react';

import { copyToClipboard } from '@/lib/clipboard';

export function useCopied(ms = 1500): [boolean, (text: string) => void] {
    const [copied, setCopied] = useState(false);
    const timer = useRef<number | null>(null);

    useEffect(() => () => {
        if (timer.current !== null) window.clearTimeout(timer.current);
    }, []);

    const copy = useCallback((text: string) => {
        copyToClipboard(text);
        setCopied(true);
        if (timer.current !== null) window.clearTimeout(timer.current);
        timer.current = window.setTimeout(() => {
            timer.current = null;
            setCopied(false);
        }, ms);
    }, [ms]);

    return [copied, copy];
}
