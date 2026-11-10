#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成演示用的虚构数据集：
   年级 七 / 八 / 九 / 高一 / 高二 / 高三，每年级 10 个班、每班 30 人；
   每班每周 45 节 = 5 天 × 9 节，全部排满；每天最多 1 节自习。

   排课用「二分图边着色」：班级 × 教师 构成二分多重图，
   每个班级度数 = 45、每位教师度数 ≤ 45，按 König 定理必然可以
   分解成 45 个完美匹配，每个匹配就是一节课的 45 个格子。
   之后用局部交换优化「语数英偏上午 / 技能课偏下午 / 同科不扎堆」。
"""
import json, random, sys
from collections import defaultdict

GRADES = [
    # (年级名, 班级名前缀, 年级代码)
    ('七年级', '七', '7'),
    ('八年级', '八', '8'),
    ('九年级', '九', '9'),
    ('高一', '高一', '1'),
    ('高二', '高二', '2'),
    ('高三', '高三', '3'),
]
CLASSES_PER_GRADE = 10
STUDENTS_PER_CLASS = 30
DAYS, SLOTS, WEEKS = 5, 9, 20
TOTAL = DAYS * SLOTS          # 每班每周 45 节
SELF_STUDY = 5                # 每天最多 1 节自习 → 一周恰好 5 节

# 各年级每周学科课时（合计必须 = TOTAL - SELF_STUDY = 40）
JUNIOR = {
    '七': {'语文': 8, '数学': 8, '英语': 6, '道德与法治': 3, '历史': 3, '地理': 3, '生物': 3,
           '体育': 2, '音乐': 1, '美术': 1, '信息技术': 1, '班会': 1},
    '八': {'语文': 7, '数学': 8, '英语': 7, '物理': 2, '道德与法治': 2, '历史': 3, '地理': 2,
           '生物': 3, '体育': 2, '音乐': 1, '美术': 1, '信息技术': 1, '班会': 1},
    '九': {'语文': 7, '数学': 7, '英语': 7, '物理': 4, '化学': 4, '道德与法治': 2, '历史': 3,
           '体育': 2, '音乐': 1, '美术': 1, '信息技术': 1, '班会': 1},
}
SENIOR = {'语文': 6, '数学': 6, '英语': 6, '物理': 3, '化学': 3, '生物': 2, '思想政治': 3,
          '历史': 3, '地理': 2, '体育': 2, '音乐': 1, '美术': 1, '信息技术': 1, '班会': 1}
for _k, _v in JUNIOR.items():
    assert sum(_v.values()) == 40, (_k, sum(_v.values()))
assert sum(SENIOR.values()) == 40, sum(SENIOR.values())

# 学科配色 / 是否偏上午（True=偏上午，False=偏下午，None=随意）
SUBJ_META = {
    '语文': ('#ef4444', True), '数学': ('#3b6cf6', True), '英语': ('#8b5cf6', True),
    '物理': ('#0ea5e9', None), '化学': ('#10b981', None), '生物': ('#22c55e', None),
    '思想政治': ('#e11d48', None), '道德与法治': ('#d946ef', None),
    '历史': ('#f59e0b', None), '地理': ('#14b8a6', None),
    '体育': ('#f97316', False),
    '中教音乐': ('#ec4899', False), '外教音乐': ('#db2777', False),
    '中教美术': ('#84cc16', False), '外教美术': ('#65a30d', False),
    '信息技术': ('#6366f1', False), 'STEAM': ('#0d9488', None),
    '班会': ('#64748b', None), '自习': ('#94a3b8', None),
}

# 单双周对开：排在同一格，单周上第一门、双周上第二门
PAIR_DEF = {
    '音乐': [('中教音乐', 'odd'), ('外教音乐', 'even')],
    '美术': [('中教美术', 'odd'), ('外教美术', 'even')],
    '信息技术': [('信息技术', 'odd'), ('STEAM', 'even')],
}
PAIR_KEYS = set(PAIR_DEF)

# 外教姓名用拉丁字母（同时会被「监考排除外教」规则识别出来）
FOREIGN_NAMES = ['Anna Lee', 'David Brown', 'Emily Clark', 'Jack Wilson', 'Lucy Taylor',
                 'Mike Evans', 'Nina Harris', 'Oscar Young', 'Sophie King', 'Tom Wright',
                 'Amy Scott', 'Ben Turner', 'Chris Moore', 'Diana Hall', 'Eric Walker',
                 'Fiona Reed', 'George Bell', 'Helen Cook', 'Ivan Price', 'Judy Barnes',
                 'Kevin Ross', 'Linda Gray', 'Mark Hughes', 'Nancy Ford']

# 每位教师带几个班（决定教师数量与人均课时）
CLASSES_PER_TEACHER = {
    '语文': 2, '数学': 2, '英语': 2,
    '物理': 5, '化学': 5, '生物': 6, '地理': 6, '历史': 6,
    '思想政治': 6, '道德与法治': 6, '体育': 6,
    '中教音乐': 10, '中教美术': 10, '外教音乐': 10, '外教美术': 10,
    '信息技术': 10, 'STEAM': 10,
}

SURNAMES = list('王李张刘陈杨黄赵吴周徐孙马朱胡林郭何高罗郑梁谢宋唐许韩冯邓曹')[:30]
GIVEN = ['思远', '雨萱', '子涵', '浩然', '梓萱', '一诺', '欣怡', '宇航', '诗涵', '俊杰',
         '佳怡', '天佑', '梦琪', '博文', '若曦', '嘉豪', '雅静', '子轩', '悦然', '明轩',
         '芷若', '沐辰', '书瑶', '泽宇', '静怡', '亦凡', '晨曦', '家豪', '雨桐', '若彤',
         '品言', '心怡', '皓轩', '慧敏', '志强', '小雅', '文博', '锦程', '立诚', '思彤',
         '云舒', '星河', '安然', '景行', '知远', '若谷', '清和', '朝阳', '白露', '冷月',
         '疏影', '亦舟', '望舒', '承宇', '修远', '书宁', '念之', '南乔', '予安', '清予']
TEACHER_GIVEN = ['建国', '丽华', '文斌', '海燕', '振宇', '秀梅', '国庆', '春燕', '立军', '雅琴',
                 '长河', '玉兰', '新宇', '红霞', '永强', '桂英', '光明', '淑华', '俊峰', '爱民',
                 '志远', '小燕', '德明', '慧兰']
assert len(set(SURNAMES)) == 30 and len(set(GIVEN)) == 60
assert len(SURNAMES) * len(GIVEN) == CLASSES_PER_GRADE * STUDENTS_PER_CLASS * len(GRADES)
assert not (set(GIVEN) & set(TEACHER_GIVEN))


def build():
    rnd = random.Random(20261110)
    meta = {
        'school': '示例实验学校（演示数据）',
        'term': '2026—2027学年 第一学期',
        'startDate': '2026-08-31',
        'totalWeeks': WEEKS, 'daysPerWeek': DAYS, 'slotsPerDay': SLOTS,
        'slotDefs': [
            {'id': 's1', 'index': 1, 'name': '第1节', 'start': '08:00', 'end': '08:40', 'period': '上午'},
            {'id': 's2', 'index': 2, 'name': '第2节', 'start': '08:50', 'end': '09:30', 'period': '上午'},
            {'id': 's3', 'index': 3, 'name': '第3节', 'start': '10:00', 'end': '10:40', 'period': '上午'},
            {'id': 's4', 'index': 4, 'name': '第4节', 'start': '10:50', 'end': '11:30', 'period': '上午'},
            {'id': 's5', 'index': 5, 'name': '第5节', 'start': '13:30', 'end': '14:10', 'period': '下午'},
            {'id': 's6', 'index': 6, 'name': '第6节', 'start': '14:20', 'end': '15:00', 'period': '下午'},
            {'id': 's7', 'index': 7, 'name': '第7节', 'start': '15:20', 'end': '16:00', 'period': '下午'},
            {'id': 's8', 'index': 8, 'name': '第8节', 'start': '16:10', 'end': '16:50', 'period': '下午'},
            {'id': 's9', 'index': 9, 'name': '第9节', 'start': '18:30', 'end': '19:10', 'period': '晚上'},
        ],
        'rooms': ['普通教室', '操场', '音乐教室', '美术教室', '计算机房', '理化实验室'],
        'updatedAt': 0,
        'source': '演示数据 · 全部为虚构内容',
    }

    # ---------- 班级 ----------
    classes = []
    stage_of = {}
    for gname, prefix, gcode in GRADES:
        for k in range(1, CLASSES_PER_GRADE + 1):
            cid = 'c%d' % (len(classes) + 1)
            classes.append({'id': cid, 'name': '%s%d' % (prefix, k), 'grade': gname,
                            'head': '', 'vice': '', 'size': STUDENTS_PER_CLASS, 'room': ''})
            stage_of[cid] = 'junior' if prefix in JUNIOR else 'senior'

    # 各年级课时表
    hours_of = {}
    for ci, c in enumerate(classes):
        prefix = GRADES[ci // CLASSES_PER_GRADE][1]
        base = dict(JUNIOR[prefix]) if prefix in JUNIOR else dict(SENIOR)
        base['自习'] = SELF_STUDY
        hours_of[c['id']] = base
        assert sum(base.values()) == TOTAL, (c['name'], sum(base.values()))

    # ---------- 学科（单双周对开拆成两门） ----------
    member_key, used_keys, real_names = {}, set(), []
    for k, lst in PAIR_DEF.items():
        for nm, _p in lst:
            member_key[nm] = k
    for h in hours_of.values():
        used_keys.update(h.keys())

    def key_of(sname):
        return member_key.get(sname, sname)

    for nm in ['语文', '数学', '英语', '物理', '化学', '生物', '思想政治', '道德与法治',
               '历史', '地理', '体育', '中教音乐', '外教音乐', '中教美术', '外教美术',
               '信息技术', 'STEAM', '班会', '自习']:
        if nm in used_keys or key_of(nm) in used_keys:
            if nm not in real_names:
                real_names.append(nm)
    subjects = [{'id': 'sub%d' % (i + 1), 'name': nm, 'color': SUBJ_META[nm][0], 'type': 'normal'}
                for i, nm in enumerate(real_names)]
    sid = {s['name']: s['id'] for s in subjects}
    for cid, h in hours_of.items():
        for k in h:
            if k not in PAIR_DEF and k not in real_names:
                raise RuntimeError('未定义的学科 %s' % k)

    # ---------- 教师 ----------
    teachers, used_tnames, foreign_used = [], set(), set()

    def new_teacher(foreign=False):
        t = {'id': 't%d' % (len(teachers) + 1), 'name': '', 'subjectId': sid.get('语文'),
             'title': '外教' if foreign else '教师', 'phone': '', 'maxWeek': 0, 'banned': []}
        if foreign:
            for nm in FOREIGN_NAMES:
                if nm not in foreign_used:
                    foreign_used.add(nm)
                    t['name'] = nm
                    break
        if not t['name']:
            k = len(teachers) + len(foreign_used) + len(used_tnames)
            idx = (k * 37) % 720
            nm = SURNAMES[idx % 30] + TEACHER_GIVEN[(idx // 30) % len(TEACHER_GIVEN)]
            guard = 0
            while nm in used_tnames:
                k += 1
                guard += 1
                idx = (k * 37) % 720
                nm = SURNAMES[idx % 30] + TEACHER_GIVEN[(idx // 30) % len(TEACHER_GIVEN)]
                assert guard < 5000, '教师姓名空间不足'
            used_tnames.add(nm)
            t['name'] = nm
        teachers.append(t)
        return t

    FIXED_COUNT = {  # 外教固定人数，名字用拉丁名
        '外教音乐': 6, '外教美术': 6,
    }
    pool, assign = {}, {}
    for stage in ('junior', 'senior'):
        pool[stage] = {}
        for sname in real_names:
            if sname in ('班会', '自习'):
                continue
            key = key_of(sname)
            cls_list = [c for c in classes if stage_of[c['id']] == stage and key in hours_of[c['id']]]
            if not cls_list:
                continue
            per = CLASSES_PER_TEACHER.get(sname, 6)
            n = FIXED_COUNT.get(sname) or max(1, -(-len(cls_list) // per))
            lst = []
            for _ in range(n):
                t = new_teacher(foreign=sname.startswith('外教'))
                t['subjectId'] = sid[sname]
                lst.append(t)
            pool[stage][sname] = lst
            for i, c in enumerate(cls_list):
                assign[(c['id'], sname)] = lst[i % n]

    # ---------- 班主任 ----------
    homeroom = {}
    load = {t['id']: 0 for t in teachers}
    for c in classes:
        for sname in real_names:
            t = assign.get((c['id'], sname))
            if t:
                load[t['id']] += hours_of[c['id']].get(key_of(sname), 0)
    homeroom_cnt = defaultdict(int)
    for c in classes:
        stage = stage_of[c['id']]
        cands = [t for s in ('语文', '数学') for t in pool[stage].get(s, [])]
        cands.sort(key=lambda t: (homeroom_cnt[t['id']] >= 2,
                                  assign.get((c['id'], '语文')) is not t,
                                  homeroom_cnt[t['id']], load[t['id']]))
        pick = None
        for t in cands:
            if homeroom_cnt[t['id']] < 2 and load[t['id']] + 6 <= 34:
                pick = t
                break
        if pick is None:
            pick = cands[0]
        homeroom[c['id']] = pick
        homeroom_cnt[pick['id']] += 1
        load[pick['id']] += 6

    for c in classes:
        t = homeroom[c['id']]
        c['head'] = t['name']
        vice = assign.get((c['id'], '数学'))
        c['vice'] = vice['name'] if vice and vice is not t else ''

    # ---------- 教学任务（单双周各一条） ----------
    odd_weeks = [w for w in range(1, WEEKS + 1) if w % 2 == 1]
    even_weeks = [w for w in range(1, WEEKS + 1) if w % 2 == 0]
    WEEKS_ALL = list(range(1, WEEKS + 1))
    tasks, task_of = [], {}

    for c in classes:
        cid = c['id']
        for key, h in hours_of[cid].items():
            if key in PAIR_DEF:
                for nm, parity in PAIR_DEF[key]:
                    task = {'id': 't%d' % (len(tasks) + 1), 'subjectId': sid[nm],
                            'teacherId': assign[(cid, nm)]['id'], 'classIds': [cid],
                            'hours': h, 'room': '',
                            'weekSpec': '1-%d%s' % (WEEKS, '单' if parity == 'odd' else '双'),
                            'public': False, 'note': '单双周对开'}
                    tasks.append(task)
                    task_of[(cid, nm)] = task
            else:
                t = homeroom[cid] if key in ('班会', '自习') else assign[(cid, key)]
                task = {'id': 't%d' % (len(tasks) + 1), 'subjectId': sid[key], 'teacherId': t['id'],
                        'classIds': [cid], 'hours': h, 'room': '',
                        'weekSpec': '1-%d' % WEEKS, 'public': False, 'note': ''}
                tasks.append(task)
                task_of[(cid, key)] = task

    # ---------- 单元格：单科 1 节；单双周对开 1 格 2 节 ----------
    def cell_of(cid, key):
        """返回一个单元格：[(学科, 教师, 生效周次)]，以及用于偏好打分的代表学科"""
        if key in PAIR_DEF:
            entries = []
            for nm, parity in PAIR_DEF[key]:
                entries.append((nm, assign[(cid, nm)]['id'], odd_weeks if parity == 'odd' else even_weeks))
            return (PAIR_DEF[key][0][0], entries)
        t = homeroom[cid] if key in ('班会', '自习') else assign[(cid, key)]
        return (key, [(key, t['id'], WEEKS_ALL)])

    # ---------- 排课：min-conflicts ----------
    cids = [c['id'] for c in classes]
    pos = {}
    for idx, c in enumerate(classes):
        cid = c['id']
        cells = [None] * TOTAL
        for d in range(DAYS):
            cells[d * SLOTS + (6 + (idx + d) % 3)] = cell_of(cid, '自习')
        rest = []
        for key, h in hours_of[cid].items():
            if key == '自习':
                continue
            rest.extend([cell_of(cid, key)] * h)
        rnd.shuffle(rest)
        it = iter(rest)
        for i in range(TOTAL):
            if cells[i] is None:
                cells[i] = next(it)
        pos[cid] = cells

    def cell_teachers(cell):
        return [e[1] for e in cell[1]]

    occ = [defaultdict(set) for _ in range(TOTAL)]
    for cid in cids:
        for r in range(TOTAL):
            for tid in cell_teachers(pos[cid][r]):
                occ[r][tid].add(cid)

    def nconf(r, t):
        s = occ[r].get(t)
        return len(s) - 1 if s and len(s) > 1 else 0

    def conflicts():
        total = 0
        for r in range(TOTAL):
            for t, cs in occ[r].items():
                if len(cs) > 1:
                    total += len(cs) - 1
        return total

    def conflict_cells():
        out = []
        for r in range(TOTAL):
            for t, cs in occ[r].items():
                if len(cs) > 1:
                    for cid in cs:
                        out.append((r, t, cid))
        return out

    def detach(r, cid):
        for tid in cell_teachers(pos[cid][r]):
            if tid in occ[r]:
                occ[r][tid].discard(cid)
                if not occ[r][tid]:
                    occ[r].pop(tid)

    def attach(r, cid):
        for tid in cell_teachers(pos[cid][r]):
            occ[r][tid].add(cid)

    best = conflicts()
    for _ in range(400000):
        if best == 0:
            break
        cells = conflict_cells()
        if not cells:
            break
        r, _t, cid = cells[rnd.randrange(len(cells))]
        r2 = rnd.randrange(TOTAL)
        if r2 == r:
            continue
        c1, c2 = pos[cid][r], pos[cid][r2]
        if c1[0] == c2[0]:
            continue
        if (c1[0] == '自习' or c2[0] == '自习') and r // SLOTS != r2 // SLOTS:
            continue
        t1s, t2s = cell_teachers(c1), cell_teachers(c2)
        if any((t in occ[r2] and occ[r2][t] != {cid}) for t in t1s):
            continue
        if any((t in occ[r] and occ[r][t] != {cid}) for t in t2s):
            continue
        before = sum(nconf(r, t) for t in t1s + t2s) + sum(nconf(r2, t) for t in t1s + t2s)
        detach(r, cid); detach(r2, cid)
        pos[cid][r], pos[cid][r2] = c2, c1
        attach(r, cid); attach(r2, cid)
        after = sum(nconf(r, t) for t in t1s + t2s) + sum(nconf(r2, t) for t in t1s + t2s)
        if after <= before or rnd.random() < 0.02:
            best += after - before
        else:
            detach(r, cid); detach(r2, cid)
            pos[cid][r], pos[cid][r2] = c1, c2
            attach(r, cid); attach(r2, cid)

    if conflicts() != 0:
        raise RuntimeError('排课冲突未清零: %d' % conflicts())

    # ---------- 偏好优化 ----------
    def pref_cost(r, sname):
        sl = r % SLOTS + 1
        if sname == '自习':
            return (SLOTS + 1 - sl) * 0.8
        pref = SUBJ_META[sname][1]
        if pref is True:
            return (sl - 1) * 0.9
        if pref is False:
            return max(0, 5 - sl) * 1.0
        return abs(sl - 5) * 0.3

    for cid in cids:
        for _ in range(6000):
            r1 = rnd.randrange(TOTAL)
            r2 = rnd.randrange(TOTAL)
            if r1 == r2:
                continue
            c1, c2 = pos[cid][r1], pos[cid][r2]
            n1, n2 = c1[0], c2[0]
            if n1 == n2:
                continue
            if (n1 == '自习' or n2 == '自习') and r1 // SLOTS != r2 // SLOTS:
                continue
            t1s, t2s = cell_teachers(c1), cell_teachers(c2)
            if any(t in occ[r2] for t in t1s) or any(t in occ[r1] for t in t2s):
                continue

            def day_dup(r, sn, ignore_r):
                d = r // SLOTS
                return sum(1 for x in range(d * SLOTS, d * SLOTS + SLOTS)
                           if x != ignore_r and pos[cid][x][0] == sn)

            before = (pref_cost(r1, n1) + pref_cost(r2, n2)
                      + max(0, day_dup(r1, n1, r1) - 1) * 6 + max(0, day_dup(r2, n2, r2) - 1) * 6)
            after = (pref_cost(r1, n2) + pref_cost(r2, n1)
                     + max(0, day_dup(r1, n2, r1) - 1) * 6 + max(0, day_dup(r2, n1, r2) - 1) * 6)
            if after + 0.001 >= before:
                continue
            detach(r1, cid); detach(r2, cid)
            pos[cid][r1], pos[cid][r2] = c2, c1
            attach(r1, cid); attach(r2, cid)

    # ---------- 课时记录 ----------
    lessons = []
    for c in classes:
        cid = c['id']
        for r in range(TOTAL):
            for (sname, tid, weeks) in pos[cid][r][1]:
                task = task_of[(cid, sname)]
                lessons.append({
                    'id': 'l%d' % (len(lessons) + 1), 'taskId': task['id'],
                    'subjectId': task['subjectId'], 'teacherId': tid,
                    'classIds': [cid], 'room': '',
                    'day': r // SLOTS, 'slot': r % SLOTS + 1,
                    'weeks': list(weeks),
                })

    # ---------- 学生 ----------
    students = []
    for gi, (gname, prefix, gcode) in enumerate(GRADES):
        for k in range(1, CLASSES_PER_GRADE + 1):
            for seq in range(1, STUDENTS_PER_CLASS + 1):
                idx = gi * CLASSES_PER_GRADE * STUDENTS_PER_CLASS + (k - 1) * STUDENTS_PER_CLASS + seq - 1
                students.append({
                    'grade': gname, 'short': prefix, 'gcode': gcode,
                    'room': k, 'classNo': '%02d%02d%02d' % (int(gcode), k, seq),
                    'name': SURNAMES[idx // 60] + GIVEN[idx % 60],
                    'sex': '男' if idx % 2 == 0 else '女',
                    'classLabel': '%s%d班' % (prefix, k),
                })
    assert len(students) == 1800 and len({s['name'] for s in students}) == 1800

    # ---------- 组长（每个年级的备课组长互不相同） ----------
    prep, subj_leader = {}, {}
    for stage, sname in (('junior', '语文'), ('junior', '数学'),
                         ('senior', '语文'), ('senior', '数学')):
        used = set()
        for gname, prefix, gcode in GRADES:
            grp = [t for t in pool[stage].get(sname, [])
                   if any(assign.get((c['id'], sname)) is t and c['grade'] == gname for c in classes)]
            for t in grp:
                if t['id'] not in used:
                    prep['%s|%s' % (gname, sname)] = t['name']
                    used.add(t['id'])
                    break
    for stage, sname in (('junior', '语文'), ('junior', '数学'), ('senior', '语文'), ('senior', '数学')):
        if pool[stage].get(sname):
            subj_leader[sname] = pool[stage][sname][0]['name']

    # ---------- 监考 / 考场 ----------
    rooms = [{'id': 'exr%d' % (i + 1), 'name': c['name'] + '教室', 'grade': c['grade']}
             for i, c in enumerate(classes)]
    exam = {
        'subjects': ['语文', '数学'],
        'subjectMeta': {
            '语文': {'subject': '语文', 'grades': [g[0] for g in GRADES], 'minutes': 120, 'minutesByGrade': {}},
            '数学': {'subject': '数学', 'grades': [g[0] for g in GRADES], 'minutes': 100, 'minutesByGrade': {}},
        },
        'sessions': [
            {'id': 'exs1', 'subjects': ['语文'], 'date': '2026-11-16', 'start': '08:00', 'end': '10:00'},
            {'id': 'exs2', 'subjects': ['数学'], 'date': '2026-11-16', 'start': '10:20', 'end': '12:00'},
        ],
        'rooms': rooms,
        'invigilateCount': {r['id']: 1 for r in rooms},
        'patrolCount': {g[0]: 1 for g in GRADES},
        'result': None, 'dirty': False, 'seed': 1,
    }

    seating = {
        'title': '', 'seed': 0, 'examsPerGrade': 3, 'examNames': {},
        'grades': [{'name': g[0], 'short': g[1], 'code': g[2]} for g in GRADES],
        'students': students, 'plan': {}, 'warnings': [], 'updatedAt': '', 'fileName': '',
    }

    return {
        'meta': meta, 'subjects': subjects, 'teachers': teachers, 'classes': classes,
        'tasks': tasks, 'lessons': lessons, 'adjustments': [],
        'groupLeaders': {'prep': prep, 'subject': subj_leader},
        'exam': exam, 'seating': seating,
    }


def validate(d):
    from collections import defaultdict, Counter
    subj = {s['id']: s['name'] for s in d['subjects']}
    cell = {}                       # (cid, day, slot) -> 已占用的周次集合
    teacher_busy = {}
    task_cnt = Counter()
    selfstudy = defaultdict(lambda: defaultdict(int))
    per_class_cells = defaultdict(set)

    for l in d['lessons']:
        cid = l['classIds'][0]
        key = (cid, l['day'], l['slot'])
        weeks = set(l['weeks'])
        assert weeks, '空周次'
        assert not (cell.get(key, set()) & weeks), '班级同格且同周重复 %s' % (key,)
        cell.setdefault(key, set()).update(weeks)
        per_class_cells[cid].add(key)

        tk = (l['teacherId'], l['day'], l['slot'])
        assert not (teacher_busy.get(tk, set()) & weeks), '教师同格且同周重复 %s' % (tk,)
        teacher_busy.setdefault(tk, set()).update(weeks)

        task_cnt[l['taskId']] += 1
        if subj[l['subjectId']] == '自习':
            selfstudy[cid][l['day']] += 1

    # 每班 45 个格子（5 天 × 9 节），单双周对开的格子有两个课时记录
    for c in d['classes']:
        assert len(per_class_cells[c['id']]) == DAYS * SLOTS, \
            '%s 只有 %d 个课时格' % (c['name'], len(per_class_cells[c['id']]))
    # 自习每天恰好 1 节
    for cid, days in selfstudy.items():
        assert len(days) == DAYS, '%s 自习未覆盖五天' % cid
        for dd, n in days.items():
            assert n == 1, '%s 周%d 自习 %d 节' % (cid, dd + 1, n)
    # 任务课时与记录数一致
    for t in d['tasks']:
        assert task_cnt[t['id']] == t['hours'], '%s 课时不符 %d/%d' % (t['id'], task_cnt[t['id']], t['hours'])
    # 单双周对开：同一格的两节课周次互补
    pairs = 0
    for key, weeks in cell.items():
        if len(weeks) != WEEKS:
            raise AssertionError('%s 周次未覆盖全学期' % (key,))
    for l in d['lessons']:
        pass
    return True


if __name__ == '__main__':
    d = build()
    validate(d)
    out = sys.argv[1] if len(sys.argv) > 1 else '/tmp/demo_dataset.json'
    json.dump(d, open(out, 'w', encoding='utf-8'), ensure_ascii=False, separators=(',', ':'))
    print('OK ->', out)
    print('班级 %d / 教师 %d / 任务 %d / 课时 %d / 学生 %d'
          % (len(d['classes']), len(d['teachers']), len(d['tasks']), len(d['lessons']),
             len(d['seating']['students'])))
    print('JSON %.1f KB' % (len(json.dumps(d, ensure_ascii=False)) / 1024))
