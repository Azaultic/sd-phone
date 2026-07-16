import React from 'react';
import ReactDOM from 'react-dom/client';

import '@fontsource/inter/latin-400.css';
import '@fontsource/inter/latin-500.css';
import '@fontsource/inter/latin-600.css';
import '@fontsource/inter/latin-700.css';
import '@fontsource/inter/latin-800.css';

import '@fontsource/great-vibes/latin-400.css';
import '@fontsource/great-vibes/latin-ext-400.css';
import '@fontsource/great-vibes/cyrillic-400.css';
import '@fontsource/great-vibes/greek-ext-400.css';
import '@fontsource/great-vibes/vietnamese-400.css';

import { App } from './App';
import { initTileCheck } from '@/apps/maps/tileCheck';
import './index.css';

initTileCheck();

document.addEventListener('mousedown', e => {
    if ((e.target as HTMLElement | null)?.closest?.('.select-text')) return;
    const sel = window.getSelection();
    if (sel && !sel.isCollapsed) sel.removeAllRanges();
});

if(import.meta.env.DEV){localStorage.setItem('sd-phone:setup:v1',JSON.stringify({completed:true,theme:'light',wallpaper:'lockscreen.jpg'}));localStorage.setItem('sd-phone:cookie:v1',JSON.stringify({cookies:25040,earned:25040,owned:{cursor:8,grandma:4},achievements:['a100','a1k','a10k','cps5'],rainOn:true}));}

ReactDOM.createRoot(document.getElementById('root')!).render(
    <React.StrictMode>
        <App />
    </React.StrictMode>,
);
