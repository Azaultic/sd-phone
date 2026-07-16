import { useEffect, useRef } from 'react';

export function useReanimateOnChange<T extends HTMLElement>(animClass: string, dep: unknown) {
    const ref = useRef<T>(null);
    const mounted = useRef(false);
    useEffect(() => {
        if (!mounted.current) { mounted.current = true; return; }
        const el = ref.current;
        if (!el) return;
        el.classList.remove(animClass);
        void el.offsetWidth;
        el.classList.add(animClass);
    }, [animClass, dep]);
    return ref;
}
