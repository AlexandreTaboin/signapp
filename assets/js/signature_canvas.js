// /assets/js/signature_canvas.js
// Module réutilisable : dessin sur canvas tactile + export base64

window.SignatureCanvas = (function() {
    'use strict';
window.APP_CSRF = document.querySelector('meta[name="csrf-token"]').content;
    function create(canvas) {
        const ctx = canvas.getContext('2d');
        let drawing = false;
        let hasContent = false;
        let lastX = 0, lastY = 0;

function resize() {
    // Sauvegarder le dessin actuel
    const prev = hasContent ? canvas.toDataURL() : null;

    // Taille CSS réelle imposée par le layout (parent / CSS)
    const rect = canvas.getBoundingClientRect();
    let cssW = rect.width;
    let cssH = rect.height;

    // Si le CSS ne fixe pas la hauteur, on la calcule
    if (cssW < 10) cssW = canvas.parentElement.clientWidth - 20;
    if (cssH < 10) cssH = cssW * (250 / 800);

    const dpr = window.devicePixelRatio || 1;
    canvas.style.width = cssW + 'px';
    canvas.style.height = cssH + 'px';
    canvas.width = Math.round(cssW * dpr);
    canvas.height = Math.round(cssH * dpr);

    // Reset transform puis scale (évite le cumul)
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);

    // Fond blanc (en coordonnées CSS grâce au scale)
    ctx.fillStyle = '#fffdf5';
    ctx.fillRect(0, 0, cssW, cssH);
    ctx.strokeStyle = '#111';
    ctx.lineWidth = 2.5;
    ctx.lineCap = 'round';
    ctx.lineJoin = 'round';

    // Restaurer le dessin si existant
    if (prev) {
        const img = new Image();
        img.onload = () => ctx.drawImage(img, 0, 0, cssW, cssH);
        img.src = prev;
    }
}

        function getPos(e) {
            const rect = canvas.getBoundingClientRect();
            const clientX = e.touches ? e.touches[0].clientX : e.clientX;
            const clientY = e.touches ? e.touches[0].clientY : e.clientY;
            return {
                x: clientX - rect.left,
                y: clientY - rect.top,
            };
        }

        function start(e) {
            e.preventDefault();
            drawing = true;
            const p = getPos(e);
            lastX = p.x;
            lastY = p.y;
        }

        function move(e) {
            if (!drawing) return;
            e.preventDefault();
            const p = getPos(e);
            ctx.beginPath();
            ctx.moveTo(lastX, lastY);
            ctx.lineTo(p.x, p.y);
            ctx.stroke();
            lastX = p.x;
            lastY = p.y;
            hasContent = true;
        }

        function end(e) {
            if (e) e.preventDefault();
            drawing = false;
        }

        canvas.addEventListener('mousedown', start);
        canvas.addEventListener('mousemove', move);
        canvas.addEventListener('mouseup', end);
        canvas.addEventListener('mouseleave', end);
        canvas.addEventListener('touchstart', start, { passive: false });
        canvas.addEventListener('touchmove', move, { passive: false });
        canvas.addEventListener('touchend', end, { passive: false });

        resize();
        window.addEventListener('resize', resize);

        return {
            clear() {
    const dpr = window.devicePixelRatio || 1;
    const cssW = canvas.width / dpr;
    const cssH = canvas.height / dpr;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.fillStyle = '#fffdf5';
    ctx.fillRect(0, 0, cssW, cssH);
    ctx.strokeStyle = '#111';
    ctx.lineWidth = 2.5;
    ctx.lineCap = 'round';
    ctx.lineJoin = 'round';
    hasContent = false;
},

            resize,
            isEmpty() { return !hasContent; },
            toBase64() {
                // Export PNG avec fond transparent : on recrée sur un canvas temporaire
                const tmp = document.createElement('canvas');
                tmp.width = canvas.width;
                tmp.height = canvas.height;
                const tctx = tmp.getContext('2d');
                // Pour garder l'écriture, on prend l'image actuelle et rend les pixels blancs transparents
                const src = ctx.getImageData(0, 0, canvas.width, canvas.height);
                for (let i = 0; i < src.data.length; i += 4) {
                    const r = src.data[i], g = src.data[i+1], b = src.data[i+2];
                    if (r > 240 && g > 235 && b > 220) {
                        src.data[i+3] = 0; // transparent
                    }
                }
                tctx.putImageData(src, 0, 0);
                return tmp.toDataURL('image/png');
            },
            disable() {
                canvas.style.pointerEvents = 'none';
                canvas.style.opacity = '0.6';
            },
        };
    }

    return { create };
})();
