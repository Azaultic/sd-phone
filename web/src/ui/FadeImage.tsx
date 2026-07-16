import { useState } from 'react';
import type { CSSProperties } from 'react';

export function FadeImage({ src, alt = '', className = '', style, loading = 'lazy', durationMs = 300 }: {
    src:         string;
    alt?:        string;
    className?:  string;
    style?:      CSSProperties;
    loading?:    'lazy' | 'eager';
    durationMs?: number;
}) {
    const [loaded, setLoaded] = useState(false);
    return (
        <img
            src={src}
            alt={alt}
            loading={loading}
            draggable={false}
            onLoad={() => setLoaded(true)}
            ref={el => { if (el?.complete) setLoaded(true); }}
            className={`${className} transition-opacity ${loaded ? 'opacity-100' : 'opacity-0'}`}
            style={{ transitionDuration: `${durationMs}ms`, ...style }}
        />
    );
}
