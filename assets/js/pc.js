// /assets/js/pc.js
// Logique PC : upload multiple, placement zones, suivi liste, téléchargement

(function() {
    'use strict';
    window.APP_CSRF = document.querySelector('meta[name="csrf-token"]').content;

    const state = {
        docId: null,
        pages: [],
        zones: [],
        activePerson: 1,
        personLabels: {},
        trackedDocs: {}, // { doc_id: {p1_label, p2_label, filename, status, signed_1, signed_2} }
        pollTimer: null,
    };

    const ZONE_W = 200;
    const ZONE_H = 70;

    const uploadForm = document.getElementById('upload-form');
    const uploadStatus = document.getElementById('upload-status');

    // ===== Upload =====
    uploadForm.addEventListener('submit', async (e) => {
        e.preventDefault();
        uploadStatus.textContent = 'Chargement en cours…';
        uploadStatus.className = 'status-msg info';

        const fd = new FormData(uploadForm);
        try {
            const r = await fetch('/api/upload.php', { method: 'POST', body: fd });
            const data = await r.json();
            if (!data.success) throw new Error(data.error || 'Erreur upload');

            state.docId = data.doc_id;
            state.pages = data.pages;
            state.zones = [];
            state.activePerson = 1;
            state.personLabels[1] = data.p1_label;
            state.personLabels[2] = data.p2_label;

            document.getElementById('label-p1').textContent = data.p1_label;
            document.getElementById('label-p2').textContent = data.p2_label;

            // Reset boutons personne
            document.querySelectorAll('.person-btn').forEach(b => b.classList.remove('active'));
            document.querySelector('.person-btn[data-person="1"]').classList.add('active');

            uploadStatus.textContent = '✓ PDF chargé';
            uploadStatus.className = 'status-msg success';

            renderPages();
            document.getElementById('step-upload').classList.add('hidden');
            document.getElementById('step-zones').classList.remove('hidden');

            document.getElementById('btn-send-tablet').disabled = true;
            document.getElementById('btn-send-tablet').textContent = '📲 Envoyer à la tablette';
        } catch (err) {
            uploadStatus.textContent = '✗ ' + err.message;
            uploadStatus.className = 'status-msg error';
        }
    });

    // ===== Pages =====
    function renderPages() {
        const container = document.getElementById('pdf-pages');
        container.innerHTML = '';
        state.pages.forEach((page, idx) => {
            const wrap = document.createElement('div');
            wrap.className = 'pdf-page-wrap';
            wrap.dataset.page = idx + 1;

            const title = document.createElement('div');
            title.className = 'page-title';
            title.textContent = `Page ${idx + 1}`;
            wrap.appendChild(title);

            const inner = document.createElement('div');
            inner.className = 'pdf-page';
            inner.style.position = 'relative';

            const img = document.createElement('img');
            img.src = page.url;
            img.draggable = false;
            img.style.display = 'block';
            img.style.width = '100%';
            img.style.height = 'auto';

            inner.appendChild(img);
            inner.addEventListener('click', (e) => onPageClick(e, idx + 1, inner, img));
            wrap.appendChild(inner);
            container.appendChild(wrap);
        });
    }

    function onPageClick(e, pageNum, container, img) {
        const rect = img.getBoundingClientRect();
        const relX = (e.clientX - rect.left) / rect.width;
        const relY = (e.clientY - rect.top) / rect.height;

        state.zones = state.zones.filter(z => !(z.person === state.activePerson));
        state.zones.push({
            person: state.activePerson,
            page: pageNum,
            rel_x: relX,
            rel_y: relY,
            rel_w: ZONE_W / rect.width,
            rel_h: ZONE_H / rect.height,
            label: state.personLabels[state.activePerson],
        });
        redrawZones();
        checkZonesComplete();
    }

    function redrawZones() {
        document.querySelectorAll('.sig-zone').forEach(el => el.remove());
        state.zones.forEach(zone => {
            const pageWrap = document.querySelector(`.pdf-page-wrap[data-page="${zone.page}"] .pdf-page`);
            if (!pageWrap) return;
            const div = document.createElement('div');
            div.className = 'sig-zone sig-zone-p' + zone.person;
            div.style.position = 'absolute';
            div.style.left = (zone.rel_x * 100) + '%';
            div.style.top = (zone.rel_y * 100) + '%';
            div.style.width = (zone.rel_w * 100) + '%';
            div.style.height = (zone.rel_h * 100) + '%';
            div.textContent = 'Signature : ' + zone.label;
            pageWrap.appendChild(div);
        });
    }

    function checkZonesComplete() {
        const hasP1 = state.zones.some(z => z.person === 1);
        const hasP2 = state.zones.some(z => z.person === 2);
        document.getElementById('btn-send-tablet').disabled = !(hasP1 && hasP2);
    }

    document.querySelectorAll('.person-btn').forEach(btn => {
        btn.addEventListener('click', () => {
            document.querySelectorAll('.person-btn').forEach(b => b.classList.remove('active'));
            btn.classList.add('active');
            state.activePerson = parseInt(btn.dataset.person, 10);
        });
    });

    document.getElementById('btn-reset-zones').addEventListener('click', () => {
        state.zones = [];
        redrawZones();
        checkZonesComplete();
    });

    // ===== Envoi tablette =====
    document.getElementById('btn-send-tablet').addEventListener('click', async () => {
        const btn = document.getElementById('btn-send-tablet');
        btn.disabled = true;
        btn.textContent = 'Envoi…';
        try {
            const r1 = await fetch('/api/set_zones.php', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    csrf_token: window.APP_CSRF,
                    doc_id: state.docId,
                    zones: state.zones,
                })
            });
            const d1 = await r1.json();
            if (!d1.success) throw new Error(d1.error);

            const r2 = await fetch('/api/send_to_tablet.php', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ csrf_token: window.APP_CSRF, doc_id: state.docId })
            });
            const d2 = await r2.json();
            if (!d2.success) throw new Error(d2.error);

            // Ajoute au suivi
            state.trackedDocs[state.docId] = {
                doc_id: state.docId,
                p1_label: state.personLabels[1],
                p2_label: state.personLabels[2],
                status: 'waiting_signatures',
                signed_1: false,
                signed_2: false,
            };

            // Reset pour nouveau document
            state.docId = null;
            state.pages = [];
            state.zones = [];
            uploadForm.reset();

            document.getElementById('step-zones').classList.add('hidden');
            document.getElementById('step-upload').classList.remove('hidden');
            document.getElementById('step-tracking').classList.remove('hidden');
            uploadStatus.textContent = '✓ Document envoyé à la tablette — vous pouvez en préparer un nouveau';
            uploadStatus.className = 'status-msg success';

            renderTracking();
            startPolling();
        } catch (err) {
            alert('Erreur : ' + err.message);
            btn.disabled = false;
            btn.textContent = '📲 Envoyer à la tablette';
        }
    });

    // ===== Suivi multiple =====
    function renderTracking() {
        const container = document.getElementById('tracking-list');
        const ids = Object.keys(state.trackedDocs);
        if (ids.length === 0) {
            container.innerHTML = '<p class="help">Aucun document en cours de signature.</p>';
            return;
        }

        container.innerHTML = ids.map(id => {
            const d = state.trackedDocs[id];
            const p1 = d.signed_1;
            const p2 = d.signed_2;
            const completed = d.status === 'completed';
            const statusLabel = completed
                ? '✓ Signé par les 2 — PDF prêt'
                : (p1 || p2 ? 'Signature en cours…' : 'En attente sur la tablette…');
            const statusClass = completed ? 'success' : (p1 || p2 ? 'pending' : 'waiting');

            return `
                <div class="tracked-doc ${statusClass}" data-id="${id}">
                    <div class="tracked-header">
                        <div class="tracked-title">📄 ${escapeHtml(d.original_filename || 'Document')}</div>
                        <div class="tracked-status status-${statusClass}">${statusLabel}</div>
                    </div>
                    <div class="tracked-signers">
                        <div class="sig-item ${p1 ? 'signed' : ''}">
                            <span class="sig-dot"></span>
                            <span class="sig-name">${escapeHtml(d.p1_label)}</span>
                            <span class="sig-state">${p1 ? '✓ Signé' : 'En attente'}</span>
                        </div>
                        <div class="sig-item ${p2 ? 'signed' : ''}">
                            <span class="sig-dot"></span>
                            <span class="sig-name">${escapeHtml(d.p2_label)}</span>
                            <span class="sig-state">${p2 ? '✓ Signé' : 'En attente'}</span>
                        </div>
                    </div>
                    ${completed ? `<button type="button" class="btn btn-success btn-dl" data-dl="${id}">⬇️ Télécharger le PDF signé</button>` : ''}
                </div>`;
        }).join('');

        container.querySelectorAll('.btn-dl').forEach(b => {
            b.addEventListener('click', () => {
                const id = b.dataset.dl;
                window.location.href = '/api/download.php?doc_id=' + encodeURIComponent(id);
                // Après téléchargement, on peut retirer de la liste après quelques secondes
                setTimeout(() => {
                    delete state.trackedDocs[id];
                    renderTracking();
                }, 2000);
            });
        });
    }

    function escapeHtml(s) {
        return String(s || '').replace(/[&<>"']/g, c => ({
            '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'
        }[c]));
    }

    function startPolling() {
        if (state.pollTimer) return;
        state.pollTimer = setInterval(pollAll, 3000);
    }

    async function pollAll() {
        const ids = Object.keys(state.trackedDocs);
        if (ids.length === 0) return;
        for (const id of ids) {
            if (state.trackedDocs[id].status === 'completed') continue;
            try {
                const r = await fetch('/api/status.php?doc_id=' + encodeURIComponent(id));
                const d = await r.json();
                if (!d.success) continue;
                state.trackedDocs[id].status = d.status;
                state.trackedDocs[id].signed_1 = d.signed_1;
                state.trackedDocs[id].signed_2 = d.signed_2;
                state.trackedDocs[id].original_filename = d.original_filename;
            } catch (e) { /* silencieux */ }
        }
        renderTracking();
    }
})();
