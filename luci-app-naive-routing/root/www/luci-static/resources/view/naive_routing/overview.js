'use strict';
'require view';
'require fs';
'require ui';
'require poll';

/* luci-app-naive-routing — naiveproxy intercept state and routing lists.
 *
 * All user-visible strings are English and wrapped into _() so that the
 * standard LuCI translation catalogs (po/ru) apply. A small built-in Russian
 * dictionary is used as a fallback when no compiled catalog is installed and
 * the browser locale is Russian.
 *
 * All system interaction goes through /usr/bin/naive-ctl: one entry point, one
 * ACL. Rules themselves are maintained by the watchdog (health.sh), the view
 * only reads state and asks for changes.
 */

var RU = {
	'Naiveproxy Routing': 'Маршрутизация naiveproxy',
	'Routing state': 'Состояние маршрутизации',
	'State': 'Состояние',
	'Tunnel': 'Туннель',
	'Exit IP (through tunnel)': 'Выходной IP (через туннель)',
	'Server address': 'Адрес сервера',
	'Rules': 'Правила',
	'Address sets': 'Наборы адресов',
	'Through the tunnel': 'Прошло через туннель',
	'Lists': 'Списки',
	'DNS backend': 'DNS-бэкенд',
	'intercept enabled': 'перехват включён',
	'disabled manually': 'выключен вручную',
	'tunnel unavailable — traffic goes direct': 'туннель недоступен — трафик напрямую',
	'unknown': 'неизвестно',
	'not running': 'не запущен',
	'rules': 'правила перехвата',
	'processes': 'процессов',
	'connections': 'соединений',
	'not installed': 'не установлен',
	'Connections to the server (speed / stealth)': 'Соединений к серверу (скорость / скрытность)',
	'naive keeps N parallel TLS connections to the server. A single connection is capped at roughly 11-13 MB/s (HTTP/2 window), so several connections speed up parallel downloads. The price: N simultaneous handshakes to one domain look less browser-like; the naive author marks this mode as insecure and recommends no more than 4. 1 is the most browser-like, 3 is about three times faster on parallel traffic.':
		'naive держит N параллельных TLS-соединений к серверу. В одном соединении потолок около 11-13 МБ/с (окно HTTP/2), поэтому несколько соединений ускоряют параллельные загрузки. Цена: N одновременных рукопожатий к одному домену выглядят менее по-браузерному; автор naive называет этот режим insecure и советует не больше 4. 1 — максимально похоже на браузер, 3 — примерно втрое быстрее на параллельном трафике.',
	'Apply and restart': 'Применить и перезапустить',
	'current': 'сейчас',
	'DNS backend (domain routing)': 'DNS-бэкенд (маршрутизация по доменам)',
	'Domain lists are turned into address sets by the DNS resolver. auto picks smartdns when present, otherwise the stock dnsmasq (requires dnsmasq-full for nftset support).':
		'Доменные списки превращаются в наборы адресов силами DNS-сервера. auto выбирает smartdns, если он есть, иначе штатный dnsmasq (для поддержки nftset нужен dnsmasq-full).',
	'Check backend': 'Проверить бэкенд',
	'Where will a domain go': 'Куда пойдёт домен',
	'Checks the lists and shows the decision: tunnel or direct.': 'Проверяет списки и показывает решение: туннель или напрямую.',
	'Check': 'Проверить',
	'goes through the tunnel': 'через туннель',
	'direct': 'напрямую',
	'Goes direct (tunnel bypass)': 'Идут напрямую (обход туннеля)',
	'Goes through the tunnel (own additions)': 'Идут через туннель (свои добавки)',
	'Save and apply': 'Сохранить и применить',
	'One domain per line, subdomains are inherited. Lines starting with # and empty lines are ignored; comments survive applying.':
		'По одному домену в строке, поддомены наследуются. Строки с # и пустые игнорируются; комментарии сохраняются при применении.',
	'Bypass list applied, rules and domain sets reloaded': 'Список обхода записан, правила и доменные наборы перечитаны',
	'Tunnel list applied, rules and domain sets reloaded': 'Список для туннеля записан, правила и доменные наборы перечитаны',
	'Done': 'Готово',
	'Error': 'Ошибка',
	'Intercept is on': 'Перехват включён',
	'Intercept is off — traffic goes direct': 'Перехват выключен — трафик идёт напрямую',
	'Connections set to': 'Соединений: ',
	'client restarted': 'клиент перезапущен',
	'DNS backend set to': 'DNS-бэкенд: ',
	'QUIC (UDP 443) towards intercepted addresses': 'QUIC (UDP 443) к перехватываемым адресам',
	'reject (force TCP)': 'отклонять (принудительно TCP)',
	'send directly': 'отправлять напрямую',
	'QUIC policy set to': 'Политика QUIC: ',
	'naive carries TCP only, therefore UDP/443 cannot be proxied. With reject the client receives an ICMP port unreachable and switches to TCP, which is intercepted, within milliseconds; the hostname does not leave the router in plaintext. With send directly the packet is not touched: HTTP/3 keeps working for addresses reachable without the tunnel, while for a blocked destination the handshake fails at the provider and the hostname is visible to it, and the client falls back to TCP only after its own timeout.':
		'naive передаёт только TCP, поэтому UDP/443 проксировать нечем. При отклонении клиент получает ICMP port unreachable и за миллисекунды переходит на TCP, который перехватывается; имя узла при этом не уходит от роутера открытым текстом. При отправке напрямую пакет не трогается: HTTP/3 продолжает работать для адресов, доступных без туннеля, но для заблокированного адреса рукопожатие обрывается у провайдера и имя узла ему видно, а клиент переходит на TCP только по своему таймауту.',
	'Components are not installed: unable to read state from naive-ctl. Install the package or check that /usr/bin/naive-ctl is executable.':
		'Компоненты не установлены: не удалось прочитать состояние из naive-ctl. Установите пакет или проверьте, что /usr/bin/naive-ctl исполняемый.',
	'Unable to write the list': 'Не удалось записать список',
	'Unable to check': 'Не удалось проверить',
	'Turn intercept off': 'Выключить перехват',
	'Turn intercept on': 'Включить перехват',
	'in the bypass list': 'в списке обхода',
	'in your tunnel additions': 'в своих добавках для туннеля',
	'in the big intercept list': 'в большом списке перехвата',
	'not in any list -> direct': 'ни в одном списке -> напрямую'
};

var lang = (navigator.language || navigator.userLanguage || '').toLowerCase();
var useRu = lang.indexOf('ru') === 0;

function tr(s) {
	if (useRu && RU[s])
		return RU[s];
	if (typeof _ === 'function')
		return _(s);
	return s;
}

function parseKV(text) {
	var out = {};
	(text || '').trim().split('\n').forEach(function(line) {
		var i = line.indexOf('=');
		if (i > 0)
			out[line.substring(0, i)] = line.substring(i + 1);
	});
	return out;
}

function humanBytes(n) {
	n = parseInt(n || 0, 10);
	var units = [ 'B', 'KB', 'MB', 'GB' ], i = 0;
	while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }
	return (i ? n.toFixed(1) : n) + ' ' + units[i];
}

return view.extend({
	load: function() {
		return Promise.all([
			fs.exec('/usr/bin/naive-ctl', [ 'status' ]).catch(function() { return { stdout: '' }; }),
			fs.read('/etc/naive-routing/direct_domains.txt').catch(function() {
				return fs.read('/etc/naive/direct_domains.txt').catch(function() { return ''; });
			}),
			fs.read('/etc/naive-routing/proxy_domains.txt').catch(function() {
				return fs.read('/etc/naive/proxy_domains.txt').catch(function() { return ''; });
			}),
			fs.exec('/usr/bin/naive-ctl', [ 'dns-check' ]).catch(function() { return { stdout: '' }; })
		]);
	},

	call: function(args, note) {
		var self = this;
		return fs.exec('/usr/bin/naive-ctl', args).then(function(res) {
			if (res && res.code !== 0)
				throw new Error((res.stderr || '').trim() || ('code ' + res.code));
			ui.addNotification(null, E('p', {}, [ note || (tr('Done') + ': ' + args.join(' ')) ]));
			return self.refresh();
		}).catch(function(err) {
			ui.addNotification(null, E('p', {}, [ tr('Error') + ': ' + err.message ]), 'danger');
		});
	},

	refresh: function() {
		var self = this;
		return fs.exec('/usr/bin/naive-ctl', [ 'status' ]).then(function(res) {
			self.fillStatus(parseKV(res.stdout));
		}).catch(function() { /* the view must not break on a missing backend */ });
	},

	fillStatus: function(st) {
		var c = this.cells;
		if (!c || !st.state) {
			if (this.missing) this.missing.style.display = '';
			return;
		}
		if (this.missing) this.missing.style.display = 'none';

		var stateText, stateClass;
		if (st.state === 'up') { stateText = tr('intercept enabled'); stateClass = 'label success'; }
		else if (st.state === 'off') { stateText = tr('disabled manually'); stateClass = 'label'; }
		else if (st.state === 'down') { stateText = tr('tunnel unavailable — traffic goes direct'); stateClass = 'label warning'; }
		else { stateText = tr('unknown'); stateClass = 'label'; }

		c.state.className = stateClass;
		c.state.textContent = stateText;
		c.exit.textContent = st.exit_ip || '—';
		c.vps.textContent = st.vps_ip || '—';
		c.tunnel.textContent = (st.tunnel_pid && st.tunnel_pid !== '0')
			? (tr('processes') + ' ' + (st.instances || 1) + ', ' + tr('connections') + ' ' + (st.concurrency || 1))
			: tr('not running');
		c.rules.textContent = (st.rules || 0) + ' ' + tr('rules');
		c.sets.textContent = (st.set_blocked || 0) + ' / ' + (st.set_static || 0) + ' / ' + (st.set_direct || 0);
		c.counters.textContent = (st.packets || 0) + ' / ' + humanBytes(st.bytes);
		c.lists.textContent = (st.direct_lines || 0) + ' / ' + (st.proxy_lines || 0) + ' / ' + (st.biglist_lines || 0);
		c.dns.textContent = st.dns_backend || tr('not installed');
		c.toggle.textContent = tr((st.enabled === '1') ? 'Turn intercept off' : 'Turn intercept on');
	},

	row: function(label, node) {
		return E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td left', style: 'width:38%' }, [ label ]),
			E('td', { 'class': 'td left' }, [ node ])
		]);
	},

	render: function(data) {
		var self = this;
		var st = parseKV(data[0] && data[0].stdout);
		var dnsCheck = parseKV(data[3] && data[3].stdout);

		this.missing = E('div', { 'class': 'cbi-section', style: (st.state ? 'display:none' : '') }, [
			E('p', { 'class': 'alert-message warning' }, [
				tr('Components are not installed: unable to read state from naive-ctl. Install the package or check that /usr/bin/naive-ctl is executable.')
			])
		]);

		this.cells = {
			state: E('span', { 'class': 'label' }, [ '—' ]),
			exit: E('span', {}, [ '—' ]),
			vps: E('span', {}, [ '—' ]),
			tunnel: E('span', {}, [ '—' ]),
			rules: E('span', {}, [ '—' ]),
			sets: E('span', {}, [ '—' ]),
			counters: E('span', {}, [ '—' ]),
			lists: E('span', {}, [ '—' ]),
			dns: E('span', {}, [ '—' ]),
			toggle: E('button', { 'class': 'cbi-button cbi-button-action' }, [ tr('Turn intercept on') ])
		};
		var c = this.cells;

		c.toggle.addEventListener('click', function() {
			var turnOn = (st.enabled !== '1');
			return self.call([ turnOn ? 'on' : 'off' ],
				tr(turnOn ? 'Intercept is on' : 'Intercept is off — traffic goes direct'));
		});

		var statusTable = E('table', { 'class': 'table' }, [
			this.row(tr('State'), c.state),
			this.row(tr('Tunnel'), c.tunnel),
			this.row(tr('Exit IP (through tunnel)'), c.exit),
			this.row(tr('Server address'), c.vps),
			this.row(tr('DNS backend'), c.dns),
			this.row(tr('Rules'), c.rules),
			this.row(tr('Address sets'), c.sets),
			this.row(tr('Through the tunnel'), c.counters),
			this.row(tr('Lists'), c.lists)
		]);

		/* --- connections to the server --- */
		var concSelect = E('select', { 'class': 'cbi-input-select' },
			[ 1, 2, 3, 4, 5, 6, 7, 8 ].map(function(n) {
				return E('option', { value: String(n) }, [ String(n) ]);
			}));
		concSelect.value = String(st.concurrency || 1);

		var concApply = E('button', { 'class': 'cbi-button cbi-button-apply' }, [ tr('Apply and restart') ]);
		concApply.addEventListener('click', function() {
			var n = concSelect.value;
			return self.call([ 'set-concurrency', n ], tr('Connections set to') + n + ' (' + tr('client restarted') + ')');
		});

		/* --- DNS backend --- */
		var BACKENDS = [ 'auto', 'smartdns', 'dnsmasq', 'none' ];
		var dnsSelect = E('select', { 'class': 'cbi-input-select' },
			BACKENDS.map(function(b) { return E('option', { value: b }, [ b ]); }));
		dnsSelect.value = st.dns_backend_opt || 'auto';

		var dnsApply = E('button', { 'class': 'cbi-button cbi-button-apply' }, [ tr('Save and apply') ]);
		dnsApply.addEventListener('click', function() {
			return self.call([ 'set-dns', dnsSelect.value ], tr('DNS backend set to') + dnsSelect.value);
		});

		var dnsCheckBtn = E('button', { 'class': 'cbi-button' }, [ tr('Check backend') ]);
		var dnsCheckOut = E('span', { style: 'margin-left:12px;opacity:.8' },
			[ dnsCheck.ok === '1' ? ('ok: ' + (dnsCheck.backend || '')) : (dnsCheck.message || '') ]);
		dnsCheckBtn.addEventListener('click', function() {
			return fs.exec('/usr/bin/naive-ctl', [ 'dns-check' ]).then(function(res) {
				var r = parseKV(res.stdout);
				dnsCheckOut.textContent = (r.ok === '1')
					? ('ok: ' + (r.backend || ''))
					: (r.message || tr('Error'));
			});
		});

		var concSection = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, [ tr('Connections to the server (speed / stealth)') ]),
			E('p', { 'class': 'cbi-section-descr' }, [ tr('naive keeps N parallel TLS connections to the server. A single connection is capped at roughly 11-13 MB/s (HTTP/2 window), so several connections speed up parallel downloads. The price: N simultaneous handshakes to one domain look less browser-like; the naive author marks this mode as insecure and recommends no more than 4. 1 is the most browser-like, 3 is about three times faster on parallel traffic.') ]),
			E('div', {}, [ concSelect, ' ', concApply,
				E('span', { style: 'margin-left:12px;opacity:.7' }, [ tr('current') + ': ' + (st.concurrency || 1) ]) ])
		]);

		var dnsSection = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, [ tr('DNS backend (domain routing)') ]),
			E('p', { 'class': 'cbi-section-descr' }, [ tr('Domain lists are turned into address sets by the DNS resolver. auto picks smartdns when present, otherwise the stock dnsmasq (requires dnsmasq-full for nftset support).') ]),
			E('div', {}, [ dnsSelect, ' ', dnsApply, ' ', dnsCheckBtn, dnsCheckOut ])
		]);

		/* --- QUIC (UDP/443) policy --- */
		var QUIC_POLICIES = [ 'reject', 'direct' ];
		var quicSelect = E('select', { 'class': 'cbi-input-select' },
			QUIC_POLICIES.map(function(v) {
				return E('option', { value: v }, [ tr(v === 'reject' ? 'reject (force TCP)' : 'send directly') ]);
			}));
		quicSelect.value = st.quic_policy || 'reject';

		var quicApply = E('button', { 'class': 'cbi-button cbi-button-apply' }, [ tr('Save and apply') ]);
		quicApply.addEventListener('click', function() {
			return self.call([ 'set-quic', quicSelect.value ], tr('QUIC policy set to') + ' ' + quicSelect.value);
		});

		var quicSection = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, [ tr('QUIC (UDP 443) towards intercepted addresses') ]),
			E('p', { 'class': 'cbi-section-descr' }, [ tr('naive carries TCP only, therefore UDP/443 cannot be proxied. With reject the client receives an ICMP port unreachable and switches to TCP, which is intercepted, within milliseconds; the hostname does not leave the router in plaintext. With send directly the packet is not touched: HTTP/3 keeps working for addresses reachable without the tunnel, while for a blocked destination the handshake fails at the provider and the hostname is visible to it, and the client falls back to TCP only after its own timeout.') ]),
			E('div', {}, [ quicSelect, ' ', quicApply,
				E('span', { style: 'margin-left:12px;opacity:.7' }, [ tr('current') + ': ' + (st.quic_policy || 'reject') ]) ])
		]);

		/* --- domain check --- */
		var checkInput = E('input', {
			'class': 'cbi-input-text',
			style: 'width:60%;min-width:220px',
			placeholder: 'example.com',
			keydown: function(ev) {
				if (ev.key === 'Enter') { ev.preventDefault(); doCheck(); }
			}
		});
		var checkResult = E('div', { style: 'margin-top:8px' }, [ '' ]);

		function doCheck() {
			var d = (checkInput.value || '').trim();
			if (!d) return;
			checkResult.textContent = '…';
			return fs.exec('/usr/bin/naive-ctl', [ 'check', d ]).then(function(res) {
				var r = parseKV(res.stdout);
				checkResult.innerHTML = '';
				var label = (r.verdict === 'tunnel')
					? E('span', { 'class': 'label warning' }, [ tr('goes through the tunnel') ])
					: E('span', { 'class': 'label success' }, [ tr('direct') ]);
				checkResult.appendChild(E('span', {}, [
					E('strong', {}, [ r.domain || d ]), ': ', label, ' — ',
					E('em', {}, [ tr(r.why || '') ]),
					r.ips ? E('span', { style: 'opacity:.7' }, [ ' (' + r.ips + ')' ]) : ''
				]));
			}).catch(function() {
				checkResult.textContent = tr('Unable to check');
			});
		}

		/* --- list editors --- */
		function listSection(title, description, path, fallbackPath, content, applyNote) {
			var area = E('textarea', {
				rows: 14,
				style: 'width:100%;font-family:monospace;font-size:12px',
				spellcheck: 'false'
			}, [ content || '' ]);

			var save = E('button', { 'class': 'cbi-button cbi-button-apply' }, [ tr('Save and apply') ]);
			save.addEventListener('click', function() {
				fs.write(path, area.value).catch(function() {
					return fs.write(fallbackPath, area.value);
				}).then(function() {
					return self.call([ 'apply' ], tr(applyNote));
				}).catch(function(err) {
					ui.addNotification(null,
						E('p', {}, [ tr('Unable to write the list') + ': ' + err.message ]), 'danger');
				});
			});

			return E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, [ tr(title) ]),
				E('p', { 'class': 'cbi-section-descr' }, [ tr(description) ]),
				area,
				E('div', { style: 'margin-top:8px' }, [ save ])
			]);
		}

		var directSection = listSection(
			'Goes direct (tunnel bypass)',
			'One domain per line, subdomains are inherited. Lines starting with # and empty lines are ignored; comments survive applying.',
			'/etc/naive-routing/direct_domains.txt', '/etc/naive/direct_domains.txt', data[1],
			'Bypass list applied, rules and domain sets reloaded');

		var proxySection = listSection(
			'Goes through the tunnel (own additions)',
			'One domain per line, subdomains are inherited. Lines starting with # and empty lines are ignored; comments survive applying.',
			'/etc/naive-routing/proxy_domains.txt', '/etc/naive/proxy_domains.txt', data[2],
			'Tunnel list applied, rules and domain sets reloaded');

		poll.add(function() { return self.refresh(); }, 5);

		this.fillStatus(st);

		return E([
			E('h2', {}, [ tr('Naiveproxy Routing') ]),
			E('p', { 'class': 'cbi-section-descr' }, [
				tr('Routing state') + ': ' +
				tr('intercept enabled') + ' / ' + tr('disabled manually') + ' / ' +
				tr('tunnel unavailable — traffic goes direct')
			]),
			this.missing,
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, [ tr('State') ]),
				statusTable,
				E('div', { style: 'margin-top:10px' }, [ c.toggle ])
			]),
			concSection,
			dnsSection,
			quicSection,
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, [ tr('Where will a domain go') ]),
				E('p', { 'class': 'cbi-section-descr' }, [ tr('Checks the lists and shows the decision: tunnel or direct.') ]),
				E('div', {}, [ checkInput, ' ',
					E('button', { 'class': 'cbi-button cbi-button-action', click: doCheck }, [ tr('Check') ]) ]),
				checkResult
			]),
			directSection,
			proxySection
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
