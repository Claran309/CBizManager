// 原型自检脚本：校验标签闭合、宽表算术自洽、人民币大写正确性。
// 该脚本只用于本地验证，不参与产品运行。
const fs = require('fs');
const path = require('path');

const html = fs.readFileSync(path.join(__dirname, 'index.html'), 'utf8');

// ---------- 1. 标签闭合 ----------
const stripped = html
  .replace(/<script[\s\S]*?<\/script>/g, '')
  .replace(/<style[\s\S]*?<\/style>/g, '')
  .replace(/<!--[\s\S]*?-->/g, '');
const voidTags = new Set(['meta', 'link', 'br', 'hr', 'img', 'input', 'source', 'option']);
const stack = [];
const tagErrors = [];
const tagRe = /<(\/?)([a-zA-Z0-9]+)([^>]*?)(\/?)>/g;
let match;
while ((match = tagRe.exec(stripped))) {
  const closing = match[1] === '/';
  const tag = match[2].toLowerCase();
  if (voidTags.has(tag) || match[4] === '/') continue;
  if (!closing) {
    stack.push(tag);
  } else {
    const top = stack.pop();
    if (top !== tag) tagErrors.push('</' + tag + '> 关闭了 <' + top + '>');
  }
}
if (stack.length) tagErrors.push('未闭合: ' + stack.join(', '));
console.log('标签错误数: ' + tagErrors.length);
tagErrors.slice(0, 5).forEach((e) => console.log('  ' + e));

// ---------- 2. 宽表算术自洽 ----------
function cellTexts(rowHtml) {
  return rowHtml
    .split('<td')
    .slice(1)
    .map((c) => c.replace(/^[^>]*>/, '').replace(/<[^>]*>/g, '').trim());
}

function checkTable(id) {
  const seg = html.slice(html.indexOf('id="' + id + '"'));
  const tbody = seg.slice(seg.indexOf('<tbody>'), seg.indexOf('</tbody>'));
  const rowHtmls = tbody.split('<tr>').slice(1);

  const groups = [];
  let current = null;
  rowHtmls.forEach((rowHtml) => {
    const firstTd = rowHtml.split('<td').slice(1)[0] || '';
    const isGroupStart = /^\s*[^>]*rowspan/.test(firstTd);
    const cells = cellTexts(rowHtml);
    if (isGroupStart) {
      current = { name: cells[0], rows: [] };
      groups.push(current);
    }
    if (!current) {
      current = { name: '', rows: [] };
      groups.push(current);
    }
    const offset = isGroupStart ? 0 : 1;
    current.rows.push({
      qty: Number((cells[5 - offset] || '').replace(/,/g, '')),
      price: Number((cells[7 - offset] || '').replace(/,/g, '')),
      amount: Number((cells[9 - offset] || '').replace(/,/g, '')),
      hasQty: (cells[5 - offset] || '').trim() !== '',
    });
  });

  let grandTotal = 0;
  let bad = 0;
  groups.forEach((group) => {
    let subtotal = 0;
    group.rows.forEach((row) => {
      if (row.hasQty) {
        const expected = Math.round(row.qty * row.price * 100) / 100;
        if (Math.abs(expected - row.amount) > 0.005) {
          bad += 1;
          console.log('  [' + id + '] 行金额不符: ' + row.qty + ' × ' + row.price + ' = ' + expected + '，表内为 ' + row.amount);
        }
        subtotal += expected;
      } else {
        subtotal += row.amount;
      }
    });
    grandTotal += subtotal;
    console.log('  [' + id + '] 分组「' + group.name.slice(0, 16) + '」小计 = ' + subtotal.toFixed(2));
  });

  const tfoot = seg.slice(seg.indexOf('<tfoot>'), seg.indexOf('</tfoot>'));
  const amounts = (tfoot.match(/[\d,]+\.\d\d/g) || []).map((x) => Number(x.replace(/,/g, '')));
  const declared = amounts[0];
  const consistent = Math.abs(grandTotal - declared) < 0.005;
  console.log('  [' + id + '] 重算总额 = ' + grandTotal.toFixed(2) + '，表内总额 = ' + declared + '，一致 = ' + consistent);
  return bad + (consistent ? 0 : 1);
}

console.log('入库宽表:');
let arithmeticErrors = checkTable('inboundWide');
console.log('出库宽表:');
arithmeticErrors += checkTable('outboundWide');
console.log('算术错误数: ' + arithmeticErrors);

// ---------- 3. 人民币大写 ----------
const script = html.match(/<script>([\s\S]*)<\/script>/)[1];
const fnSource = script.slice(script.indexOf('var RMB_DIGITS'), script.indexOf('/* ---------- 3.'));
eval(fnSource);

const cases = [
  [0, 'RMB零元整'],
  [1, 'RMB壹元整'],
  [10, 'RMB壹拾元整'],
  [100.05, 'RMB壹佰元零伍分'],
  [10001, 'RMB壹万零壹元整'],
  [72000, 'RMB柒万贰仟元整'],
  [100000000, 'RMB壹亿元整'],
  [1000001, 'RMB壹佰万零壹元整'],
  [10010001, 'RMB壹仟零壹万零壹元整'],
  [147092, 'RMB壹拾肆万柒仟零玖拾贰元整'],
  [173520, 'RMB壹拾柒万叁仟伍佰贰拾元整'],
  [173520.05, 'RMB壹拾柒万叁仟伍佰贰拾元零伍分'],
];
let upperErrors = 0;
cases.forEach(([value, want]) => {
  const got = rmbUpper(value);
  if (got !== want) {
    upperErrors += 1;
    console.log('大写不符: ' + value + ' => ' + got + '，期望 ' + want);
  }
});
console.log('大写错误数: ' + upperErrors);

const failed = tagErrors.length + arithmeticErrors + upperErrors;
console.log(failed === 0 ? '自检通过' : '自检失败，共 ' + failed + ' 项');
process.exit(failed === 0 ? 0 : 1);
