const root = document.querySelector('#app');
const token = new URLSearchParams(location.search).get('access');
const config = window.SANTA_CONFIG || {};
const client = config.url?.startsWith('http') ? window.supabase.createClient(config.url, config.key) : null;
let data;
const nice = { lovely: 'Lovely', would_love: 'Would love', dream_gift: 'Dream gift' };

function esc(value = '') { return String(value).replace(/[&<>'"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[c])); }
function linkFor(next) { return `${location.origin}${location.pathname}?access=${next}`; }
function message(text) { root.insertAdjacentHTML('afterbegin', `<p class="notice">${esc(text)}</p>`); setTimeout(() => root.querySelector('.notice')?.remove(), 3500); }
async function rpc(name, args) { const { data, error } = await client.rpc(name, args); if (error) throw error; return data; }

function wishCard(wish, role) {
  const action = role === 'family_viewer'
    ? (wish.reserved ? '<span class="reserved">Reserved for Santa</span>' : `<button class="reserve" data-reserve="${wish.id}">I’ll get this</button>`)
    : `<button class="remove" data-remove="${wish.id}">Remove</button>`;
  return `<article class="wish"><div><span class="priority ${wish.priority}">${nice[wish.priority]}</span><h3>${esc(wish.title)}</h3>${wish.notes ? `<p>${esc(wish.notes)}</p>` : ''}${wish.url ? `<a href="${esc(wish.url)}" target="_blank" rel="noreferrer">View idea</a>` : ''}</div>${action}</article>`;
}

function render() {
  const { role, group, children, wishes, childId } = data;
  if (role === 'admin') {
    root.innerHTML = `<div class="eyebrow">Family organiser</div><h1>${esc(group.name)}</h1><p class="lead">Add each child, then share their edit link with them. The family link is for grandparents and gift allocators only.</p>
      <div class="linkbox"><strong>Family gift link</strong><code id="family-link">Create one below</code><button id="new-family-link">Create family gift link</button></div>
      <form id="add-child" class="inline"><input name="name" required maxlength="60" placeholder="Child’s name" /><button>Add child</button></form>
      <section class="children">${children.length ? children.map(c => `<div class="child"><b>${esc(c.name)}</b><span>${wishes.filter(w => w.childId === c.id).length} wishes</span></div>`).join('') : '<p class="empty">Start with Maansi, Yuvaan and their cousin.</p>'}</section>`;
    return;
  }
  const grouped = children.map(c => ({...c, wishes: wishes.filter(w => w.childId === c.id)}));
  root.innerHTML = `<div class="eyebrow">${role === 'child_editor' ? 'Your Santa list' : 'Family gift list'}</div><h1>${role === 'child_editor' ? `Hi ${esc(children[0]?.name || '')}!` : esc(group.name)}</h1>
    <p class="lead">${role === 'child_editor' ? 'Add the things you would love Santa to know about.' : 'Choose a wish to make Christmas magic. Reservations stay hidden from the kids.'}</p>
    ${role === 'child_editor' ? `<form id="add-wish" class="wish-form"><input name="title" required maxlength="180" placeholder="What would you like?" /><select name="priority"><option value="lovely">Lovely</option><option value="would_love" selected>Would love</option><option value="dream_gift">Dream gift</option></select><input name="url" type="url" placeholder="A link (optional)" /><textarea name="notes" maxlength="300" placeholder="Colour, size or a little note (optional)"></textarea><button>Add to my list</button></form>` : ''}
    <section class="lists">${grouped.map(c => `<div class="list"><h2>${esc(c.name)}’s wishes <span>${c.wishes.length}</span></h2>${c.wishes.length ? c.wishes.map(w => wishCard(w, role)).join('') : '<p class="empty">No wishes added yet.</p>'}</div>`).join('')}</section>`;
}

async function load() {
  if (!token) { root.innerHTML = '<h1>Santa Squad</h1><p class="lead">This is a family-only list. Open the special link you were sent.</p>'; return; }
  if (!client) { root.innerHTML = '<h1>Almost ready</h1><p>The family organiser still needs to connect Santa Squad.</p>'; return; }
  try { data = await rpc('portal_for', { p_token: token }); render(); }
  catch (error) { root.innerHTML = `<h1>That link needs a check</h1><p class="lead">${esc(error.message || 'Please ask the family organiser for a fresh link.')}</p>`; }
}

root.addEventListener('submit', async e => {
  e.preventDefault(); const form = e.target; const f = new FormData(form);
  try {
    if (form.id === 'add-wish') await rpc('add_wish', { p_token: token, p_title: f.get('title'), p_url: f.get('url'), p_notes: f.get('notes'), p_priority: f.get('priority') });
    if (form.id === 'add-child') { const child = await rpc('create_child_link', { p_token: token, p_name: f.get('name') }); await navigator.clipboard?.writeText(linkFor(child.token)); message(`${child.name}’s edit link copied — send it to them.`); }
    form.reset(); await load();
  } catch (error) { message(error.message); }
});
root.addEventListener('click', async e => {
  const reserve = e.target.dataset.reserve, remove = e.target.dataset.remove;
  try {
    if (reserve) { const name = prompt('Your name, so the family knows this one is covered:'); if (!name) return; await rpc('reserve_wish', { p_token: token, p_wish_id: reserve, p_name: name, p_note: null }); message('Lovely — that gift is now reserved.'); }
    if (remove && confirm('Remove this wish?')) { await rpc('remove_wish', { p_token: token, p_wish_id: remove }); }
    if (e.target.id === 'new-family-link') { const newToken = await rpc('create_family_viewer_link', { p_token: token }); const value = linkFor(newToken); document.querySelector('#family-link').textContent = value; await navigator.clipboard?.writeText(value); message('Family gift link copied.'); return; }
    if (reserve || remove) await load();
  } catch (error) { message(error.message); }
});
load();
