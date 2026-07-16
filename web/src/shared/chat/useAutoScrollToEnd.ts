import { useEffect, type RefObject } from 'react';

export function useAutoScrollToEnd<T extends HTMLElement>(ref: RefObject<T>, dep: unknown, enabled = true) {
    useEffect(() => {
        if (!enabled) return;
        const el = ref.current;
        if (el) el.scrollTop = el.scrollHeight;
    }, [ref, dep, enabled]);
}
