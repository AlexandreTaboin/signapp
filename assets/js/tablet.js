// /assets/js/tablet.js
// Logique tablette : liste de documents, sélection, signature, retour à la liste

(function() {
    'use strict';
    window.APP_CSRF = document.querySelector('meta[name="csrf-token"]').content;

    const state = {
        currentDocId: null,
		readingPage: 1,
        readingTotalPages: 1,
        readingZoom: 1,
        currentDocData: null,
        sigInstance: null,
        activeZone: null,
        pollTimer: null,
        lockUntil: 0,
        mode: 'list', // 'list' | 'document'
    };

    // DOM
    const listScreen = document.getElementById('list-screen');
    const docScreen = document.getElementById('document-screen');
    const listEl = document.getElementById('documents-list');
    const listCount = document.getElementById('list-count');
    const emptyState = document.getElementById('empty-state');
    const pagesContainer = document.getElementById('pages-container');
    const sigPanel = document.getElementById('signature-panel');
    const sigTitle = document.getElementById('sig-zone-label');
    const banner = document.getElementById('current-signer-banner');
    const canvas = document.getElementById('signature-canvas');
    const btnClear = document.getElementById('btn-clear');
    const btnValidate = document.getElementById('btn-validate');
    const btnBack = document.getElementById('btn-back');
    const toast = document.getElementById('toast');
	const readingScreen = document.getElementById('reading-screen');
    const readingTitle = document.getElementById('reading-title');
    const readingImg = document.getElementById('reading-page-img');
    const readingWrapper = document.getElementById('reading-page-wrapper');
    const pageCurrentEl = document.getElementById('page-current');
    const pageTotalEl = document.getElementById('page-total');
    const btnPrevPage = document.getElementById('btn-prev-page');
    const btnNextPage = document.getElementById('btn-next-page');
    const btnStartSigning = document.getElementById('btn-start-signing');
    const btnBackList = document.getElementById('btn-back-list');
    const btnZoomIn = document.getElementById('btn-zoom-in');
    const btnZoomOut = document.getElementById('btn-zoom-out');
    const btnZoomReset = document.getElementById('btn-zoom-reset');

    state.sigInstance = SignatureCanvas.create(canvas);

    btnClear.addEventListener('click', () => state.sigInstance.clear());
    btnBack.addEventListener('click', () => returnToList());

    function showScreen(name) {
        listScreen.classList.toggle('hidden', name !== 'list');
        readingScreen.classList.toggle('hidden', name !== 'reading');
        docScreen.classList.toggle('hidden', name !== 'document');
    }

    function showToast(message, type = 'success') {
        const icon = toast.querySelector('.toast-icon');
        const text = toast.querySelector('.toast-text');
        icon.textContent = type === 'success' ? '✓' : '⚠';
        text.textContent = message;
        toast.className = 'toast ' + type;
        setTimeout(() => toast.classList.add('hidden'), 2500);
    }

    // ============= ÉCRAN LISTE =============
    async function refreshList() {
        if (state.mode !== 'list') return;
        try {
            const r = await fetch('/api/status.php?list=1');
            const d = await r.json();
            if (!d.success) return;
            renderList(d.documents || []);
        } catch (e) { /* silencieux */ }
    }

    function renderList(docs) {
        listCount.textContent = docs.length;

        if (docs.length === 0) {
            listEl.innerHTML = '';
            emptyState.classList.remove('hidden');
            return;
        }
        emptyState.classList.add('hidden');

        listEl.innerHTML = docs.map(d => {
            const p1Done = d.signed_1;
            const p2Done = d.signed_2;
            const sentDate = d.sent_at ? new Date(d.sent_at * 1000).toLocaleString('fr-FR', {
                day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit'
            }) : '';
            const progressText = p1Done
                ? `Plus que ${d.p2_label} à signer`
                : `${d.p1_label} et ${d.p2_label}`;

            return `
                <div class="doc-card" data-id="${d.doc_id}">
                    <div class="doc-card-header">
                        <div class="doc-card-icon">📄</div>
                        <div class="doc-card-title">
                            <div class="doc-filename">${escapeHtml(d.original_filename)}</div>
                            <div class="doc-date">Envoyé le ${sentDate}</div>
                        </div>
                    </div>
                    <div class="doc-signers">
                        <div class="signer-chip ${p1Done ? 'done' : ''}">
                            ${p1Done ? '✓' : '✍️'} ${escapeHtml(d.p1_label)}
                        </div>
                        <div class="signer-chip ${p2Done ? 'done' : ''}">
                            ${p2Done ? '✓' : '✍️'} ${escapeHtml(d.p2_label)}
                        </div>
                    </div>
                    <div class="doc-action">
                        <span class="doc-progress">${escapeHtml(progressText)}</span>
                        <span class="doc-arrow">→</span>
                    </div>
                </div>`;
        }).join('');

        listEl.querySelectorAll('.doc-card').forEach(card => {
            card.addEventListener('click', () => openDocument(card.dataset.id));
        });
    }

    function escapeHtml(s) {
        return String(s || '').replace(/[&<>"']/g, c => ({
            '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'
        }[c]));
    }

    // ============= OUVERTURE DOCUMENT =============
    async function openDocument(docId) {
        try {
            const r = await fetch('/api/status.php?doc_id=' + encodeURIComponent(docId));
            const d = await r.json();
            if (!d.success || !d.document) {
                showToast('Document indisponible', 'error');
                refreshList();
                return;
            }
            state.currentDocId = d.document.doc_id;
            state.currentDocData = d.document;
            openReadingScreen(d.document);
        } catch (e) {
            showToast('Erreur de chargement', 'error');
        }
    }

    function openReadingScreen(doc) {
        readingTitle.textContent = doc.original_filename || doc.filename || 'Document';
        state.readingPage = 1;
        state.readingTotalPages = doc.pages.length;
        state.readingZoom = 1;
        pageTotalEl.textContent = state.readingTotalPages;
        renderReadingPage();
        showScreen('reading');
    }

    function renderReadingPage() {
        const doc = state.currentDocData;
        if (!doc) return;
        const page = doc.pages[state.readingPage - 1];
        // Adapte selon la structure réelle renvoyée par status.php
        readingImg.src = page.image_url || page.url || page.preview_url || page;
        pageCurrentEl.textContent = state.readingPage;
        btnPrevPage.disabled = state.readingPage <= 1;
        btnNextPage.disabled = state.readingPage >= state.readingTotalPages;
        applyZoom();
    }

    function applyZoom() {
        readingWrapper.style.transform = `scale(${state.readingZoom})`;
    }

    btnPrevPage.addEventListener('click', () => {
        if (state.readingPage > 1) { state.readingPage--; renderReadingPage(); }
    });
    btnNextPage.addEventListener('click', () => {
        if (state.readingPage < state.readingTotalPages) { state.readingPage++; renderReadingPage(); }
    });
    btnZoomIn.addEventListener('click', () => {
        state.readingZoom = Math.min(3, state.readingZoom + 0.25);
        applyZoom();
    });
    btnZoomOut.addEventListener('click', () => {
        state.readingZoom = Math.max(0.5, state.readingZoom - 0.25);
        applyZoom();
    });
    btnZoomReset.addEventListener('click', () => {
        state.readingZoom = 1;
        applyZoom();
    });
    let lastTap = 0;
    readingImg.addEventListener('click', () => {
        const now = Date.now();
        if (now - lastTap < 300) {
            state.readingZoom = state.readingZoom === 1 ? 2 : 1;
            applyZoom();
        }
        lastTap = now;
    });

    btnBackList.addEventListener('click', () => {
        state.currentDocId = null;
        state.currentDocData = null;
        showScreen('list');
        refreshList();
    });

    btnStartSigning.addEventListener('click', () => {
        renderDocument(state.currentDocData);
        updateSignerPanel(state.currentDocData);
        showScreen('document');
    });

    function renderDocument(doc) {
        pagesContainer.innerHTML = '';
        document.getElementById('doc-title').textContent =
            `${doc.p1_label} & ${doc.p2_label}`;

        doc.pages.forEach((page, idx) => {
            const wrap = document.createElement('div');
            wrap.className = 'tablet-page-wrap';
            wrap.dataset.page = idx + 1;

            const inner = document.createElement('div');
            inner.className = 'tablet-page';
            inner.style.position = 'relative';

            const img = document.createElement('img');
            img.src = page.url;
            img.draggable = false;
            inner.appendChild(img);

            doc.zones.filter(z => z.page === (idx + 1)).forEach(zone => {
                const zd = document.createElement('div');
                zd.className = 'tablet-sig-zone sig-zone-p' + zone.person;
                zd.style.left = (zone.rel_x * 100) + '%';
                zd.style.top = (zone.rel_y * 100) + '%';
                zd.style.width = (zone.rel_w * 100) + '%';
                zd.style.height = (zone.rel_h * 100) + '%';
                zd.dataset.person = zone.person;
                zd.textContent = 'Signature : ' + zone.label;
                inner.appendChild(zd);
            });

            wrap.appendChild(inner);
            pagesContainer.appendChild(wrap);
        });
    }

    function updateSignerPanel(doc) {
        const p1Done = !!doc.signed_1;
        const p2Done = !!doc.signed_2;

        document.querySelectorAll('.tablet-sig-zone').forEach(z => {
            const p = parseInt(z.dataset.person, 10);
            if ((p === 1 && p1Done) || (p === 2 && p2Done)) {
                z.classList.add('signed');
                z.textContent = '✓ Signé';
            }
        });

        let nextPerson = null;
        if (!p1Done) nextPerson = 1;
        else if (!p2Done) nextPerson = 2;

        if (nextPerson === null) {
            sigPanel.classList.add('hidden');
            return;
        }

        const label = nextPerson === 1 ? doc.p1_label : doc.p2_label;
        banner.textContent = `✍️ À ${label} de signer`;
        banner.className = 'signer-banner person-' + nextPerson;
        sigTitle.textContent = `Signature de : ${label}`;
        state.activeZone = nextPerson;
        sigPanel.classList.remove('hidden');
        requestAnimationFrame(() => requestAnimationFrame(() => {
            if (state.sigInstance && state.sigInstance.resize) state.sigInstance.resize();
        }));
    }

    // ============= VALIDATION SIGNATURE =============
    btnValidate.addEventListener('click', async () => {
        if (state.sigInstance.isEmpty()) {
            alert('Veuillez signer avant de valider.');
            return;
        }
        if (!state.activeZone || !state.currentDocId) return;

        btnValidate.disabled = true;
        btnValidate.textContent = 'Envoi…';
        state.lockUntil = Date.now() + 5000;

        const b64 = state.sigInstance.toBase64();

        try {
            const r = await fetch('/api/sign.php', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    csrf_token: window.APP_CSRF,
                    doc_id: state.currentDocId,
                    person: state.activeZone,
                    signature: b64,
                })
            });
            const d = await r.json();
            if (!d.success) throw new Error(d.error || 'Erreur');

            state.sigInstance.clear();
            btnValidate.disabled = false;
            btnValidate.textContent = '✓ Valider ma signature';
            state.lockUntil = 0;

            showToast('Signature enregistrée ✓');
            returnToList();
        } catch (err) {
            alert('Erreur : ' + err.message);
            btnValidate.disabled = false;
            btnValidate.textContent = '✓ Valider ma signature';
            state.lockUntil = 0;
        }
    });

    function returnToList() {
        sigPanel.classList.add('hidden');
        state.activeZone = null;
        state.currentDocId = null;
        state.currentDocData = null;
        pagesContainer.innerHTML = '';
        showScreen('list');
        refreshList();
    }

    // ============= POLLING =============
    function startPoll() {
        refreshList();
        state.pollTimer = setInterval(() => {
            if (Date.now() < state.lockUntil) return;
            if (state.mode === 'list') {
                refreshList();
            }
            // En mode document, pas de refresh auto pour ne pas perturber la signature
        }, 3000);
    }

    showScreen('list');
    startPoll();
})();
