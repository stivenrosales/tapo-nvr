/**
 * Daily camera summary mailer.
 *
 * The tablet uploads Camara/resumenes/YYYY-MM-DD.json around 20:55 (Lima).
 * This script reads today's file and emails it, with a link to every clip.
 *
 * Install: paste into a new project at script.google.com, select `setup`
 * and press Run once. It asks for permissions and schedules the daily run.
 */

const ROOT_FOLDER = 'Camara';
const SUMMARY_FOLDER = 'resumenes';
const SEND_HOUR = 21; // Apps Script fires somewhere within 21:00–22:00.
const TIME_ZONE = 'America/Lima';
const DAYS = ['dom', 'lun', 'mar', 'mié', 'jue', 'vie', 'sáb'];
const MONTHS = ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic'];

// Spanish 'dom 4 oct' or, with time, 'dom 4 12:14' (Utilities.formatDate only speaks English).
function fmt_(date, withTime) {
  const [dow, day, month, hm] = Utilities.formatDate(date, TIME_ZONE, 'u|d|M|HH:mm').split('|');
  return DAYS[Number(dow) % 7] + ' ' + day + ' ' + (withTime ? hm : MONTHS[Number(month) - 1]);
}

function setup() {
  ScriptApp.getProjectTriggers()
    .filter(t => t.getHandlerFunction() === 'sendDailySummary')
    .forEach(t => ScriptApp.deleteTrigger(t));
  ScriptApp.newTrigger('sendDailySummary')
    .timeBased()
    .everyDays(1)
    .atHour(SEND_HOUR)
    .inTimezone(TIME_ZONE)
    .create();
  // Send one right away so the user can see what it looks like.
  sendDailySummary();
}

function sendDailySummary() {
  const today = Utilities.formatDate(new Date(), TIME_ZONE, 'yyyy-MM-dd');
  const to = Session.getEffectiveUser().getEmail();
  const root = findFolder_(DriveApp.getRootFolder(), ROOT_FOLDER);
  const summaries = root && findFolder_(root, SUMMARY_FOLDER);
  const file = summaries && findFile_(summaries, today + '.json');

  if (!file) {
    // A missing summary is itself a warning sign: the tablet did not report.
    MailApp.sendEmail({
      to: to,
      subject: '⚠️ Cámara — no llegó el resumen de hoy (' + today + ')',
      htmlBody: '<p>La tablet no subió <code>' + ROOT_FOLDER + '/' + SUMMARY_FOLDER + '/' +
        today + '.json</code>.</p><p>Revisa si la tablet está prendida, conectada al Wi-Fi ' +
        'y desbloqueada después del último reinicio.</p>',
    });
    return;
  }

  const s = JSON.parse(file.getBlob().getDataAsString());
  MailApp.sendEmail({ to: to, subject: subject_(s), htmlBody: body_(s, root) });
}

function subject_(s) {
  const day = fmt_(new Date(s.window_end), false);
  const alert = s.incidents && s.incidents.length ? ' · ⚠️ ' + s.incidents.length + ' incidente(s)' : '';
  return '📹 Cámara — ' + day + ' · ' + s.uploaded + ' subido(s), ' + s.discarded + ' descartado(s)' + alert;
}

function body_(s, root) {
  const esc = t => String(t).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const from = fmt_(new Date(s.window_start), true);
  const to = fmt_(new Date(s.window_end), true);

  const stat = (label, value) =>
    '<td style="padding:8px 14px;text-align:center"><div style="font-size:22px;font-weight:600">' +
    value + '</div><div style="color:#666;font-size:12px">' + label + '</div></td>';

  let html = '<div style="font-family:-apple-system,Segoe UI,Roboto,sans-serif;max-width:560px">' +
    '<p style="color:#666">Del ' + esc(from) + ' al ' + esc(to) + '</p>' +
    '<table style="border-collapse:collapse;background:#f6f6f6;border-radius:8px"><tr>' +
    stat('eventos', s.events) + stat('subidos', s.uploaded) + stat('descartados', s.discarded) +
    stat('retenidos', s.held) + stat('reinicios', s.restarts) + '</tr></table>';

  if (s.clips && s.clips.length) {
    html += '<h3 style="margin-top:20px">Clips subidos</h3><table style="border-collapse:collapse">';
    s.clips.forEach(c => {
      const url = clipUrl_(root, c.folder, c.file);
      const labels = (c.labels || [])
        .map(l => esc(l.class) + ' (' + Number(l.conf).toFixed(2) + ')').join(', ') || '—';
      html += '<tr><td style="padding:4px 12px 4px 0;font-weight:600">' + esc(c.time) + '</td>' +
        '<td style="padding:4px 12px 4px 0">' + labels + '</td>' +
        '<td style="padding:4px 0">' + (url ? '<a href="' + esc(url) + '">▶ ver</a>' : esc(c.file)) +
        '</td></tr>';
    });
    html += '</table>';
  } else {
    html += '<p style="margin-top:20px">Sin clips subidos: no pasó nadie (o nada) que valiera la pena.</p>';
  }

  if (s.incidents && s.incidents.length) {
    html += '<h3 style="margin-top:20px">⚠️ Incidentes</h3><ul>' +
      s.incidents.map(i => '<li>' + esc(i.time) + ' — ' + esc(i.msg) + '</li>').join('') + '</ul>';
  }
  if (s.gate_errors) {
    html += '<p>⚠️ El filtro falló ' + s.gate_errors + ' vez/veces; esos clips quedaron retenidos en la tablet.</p>';
  }
  return html + '</div>';
}

function clipUrl_(root, folderName, fileName) {
  const folder = findFolder_(root, folderName);
  const file = folder && findFile_(folder, fileName);
  return file ? file.getUrl() : null;
}

function findFolder_(parent, name) {
  const it = parent.getFoldersByName(name);
  return it.hasNext() ? it.next() : null;
}

function findFile_(parent, name) {
  const it = parent.getFilesByName(name);
  return it.hasNext() ? it.next() : null;
}
