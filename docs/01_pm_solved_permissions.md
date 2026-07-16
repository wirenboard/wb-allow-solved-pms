# 01. Права на «Отметить решением» в личных сообщениях

**Плагин:** `wb-allow-solved-pms` v0.3.0 (`1041085`)
**Проверено на:** стейджинг `discourse-sandbox.hq.wirenboard.com`, Discourse **2026.4.0**, 2026-07-16
**Контекст:** починка резолва group-настроек по итогам код-ревью v0.2.0 (`TASK-fix-group-settings-and-tests.md`)

---

## 1. Что делает плагин

Пре-пендит `Guardian#can_accept_answer?`:

- **не-PM топики** → уходят в `super` **без изменений**, ядро решает само;
- **PM-топики** → правила ядра **полностью заменяются** на описанные ниже.

`can_unaccept_answer?` отдельно не патчится: ядро определяет его через `can_accept_answer?`
(`can_accept_answer?(topic, post) || (is_staff? && topic&.solved.present?)`), поэтому патч
покрывает и его.

### Отношение к ядру

Ядро (bundled `discourse-solved`) **само умеет solved в групповых PM** — настройка
`allow_solved_in_groups`, плюс `allow_solved_on_all_topics` (на стейджинге = `true`, а это в
ядре проверяется **до** ветки `private_message?`, то есть ядро разрешило бы solved и в ЛС).

Так как плагин перехватывает **все** PM, **обе эти настройки ядра внутри PM не работают**,
пока плагин установлен — включая случай `solved_pm_enabled=false`, когда solved в ЛС
запрещён вообще. Если нужен только групповой инбокс без доп. гейтов — возможно, плагин
не нужен, хватит `allow_solved_in_groups`. См. п.7.

---

## 2. Модель прав

### 2.1. Какие топики eligible

```
PM содержит >= 1 allowed group?
├── да  → solved_pm_target_groups пуст                → eligible
│         solved_pm_target_groups пересекается        → eligible
│         иначе (в т.ч. значение не резолвится)       → НЕ eligible   ← fail closed
└── нет → solved_pm_allow_personal_messages = true
          И ровно 2 участника                         → eligible
          иначе                                       → НЕ eligible
```

Две ветки **независимы**: групповые инбоксы гейтятся `target_groups`, личные 1:1 —
`allow_personal_messages`. Можно одновременно держать ограниченный support-инбокс и
разрешённые 1:1.

PM без групп, но с 3+ участниками, не eligible никогда (настройка называется «1:1» и
означает буквально 1:1).

### 2.2. Кто может отметить решение (внутри eligible-топика)

| Актор | Может? | Чем управляется |
|---|---|---|
| staff (admin/moderator) | **всегда** | ничем, хардкод |
| член `solved_pm_actor_groups` | да | `solved_pm_actor_groups` |
| автор топика | если включено | `solved_pm_allow_topic_owner` |
| остальные участники | нет | — |

`solved_pm_actor_groups` **только добавляет** акторов; ограничить staff ею нельзя (решение B4, п.4).

### 2.3. Guardrails (проверяются до всего вышеперечисленного)

Пост: `post_type == regular`, не первый (`post_number > 1`), не whisper, не удалён, принадлежит
этому топику, не от системного юзера. Топик: не closed, не archived. Плюс `can_see?` на топик и пост.

> Closed/archived PM запрещены **всем, включая staff** — в ядре staff в закрытых топиках solved
> ставить может. Унаследованное поведение v0.2.0, сознательно не менялось.

---

## 3. Формат значений `group_list` — грабли

`solved_pm_target_groups` и `solved_pm_actor_groups` имеют `type: group_list`.
**Discourse хранит их как pipe-delimited group _id_** (`44|3`), админка пишет именно id.

Резолвер (`WbAllowSolvedPms.group_ids_from_setting`) принимает **и id, и имена**
(регистронезависимо), и смешанные значения — иначе грязные значения на живых порталах
перестали бы работать:

| Значение | Резолвится в |
|---|---|
| `44` | `[44]` |
| `support` | `[44]` (по имени) |
| `support\|44\|3` | `[44, 3]` (дедуп) |
| `no_such_group` | `[]` → **мисконфиг**, fail closed + warn |
| `0` | `[]` — **никогда** не пропускается |

### 3.1. Ловушка `SiteSetting.*_map` — не использовать

Штатный хелпер `_map` — это `split("|").map(&:to_i)`, а `"support".to_i == 0`, и **группа 0 =
everyone**. Воспроизведено на стейджинге живьём:

```ruby
SiteSetting.solved_pm_target_groups = "support|44|3"
SiteSetting.solved_pm_target_groups_map   # => [0, 44, 3]   ← 0 = everyone
```

Поэтому наивный переход на `_map` раздал бы настройку всему сайту. Резолвер выкидывает
`0` и непозитивные id. Регрессия закрыта спекой
(`spec/lib/wb_allow_solved_pms_spec.rb`, «avoids the SiteSetting#..._map trap»).

### 3.2. Валидации у `group_list` нет

К `type: group_list` по умолчанию **не привязан валидатор** — `SiteSetting.x = "support|44|3"`
принимается как есть. Именно так на проде и осели имена: дефолт `"support"` из `settings.yml`
засеялся, владелец дописал к нему id через админку. Дефолты в `settings.yml` теперь пустые.

---

## 4. Принятые решения (decision log)

| # | Решение | Почему |
|---|---|---|
| B2 | Непустая, но нерезолвящаяся target-настройка → **fail closed** + warn, а не «ограничений нет» | Расширение прав хуже отказа. Выпадает из структуры само: непустой список ∩ `[]` = `[]` |
| B2 | Fail closed применяется **только в групповой ветке** | Там настройка и читается. 1:1 гейтится своей настройкой — иначе B5 снова связал бы их |
| B4 | **staff может всегда**, `actor_groups` только добавляет | Как в ядре (`return true if is_staff?`). Текст настройки поправлен вместо кода |
| B5 | Группы и 1:1 разведены в независимые ветки | Требование ТЗ; раньше непустой target делал 1:1 невключаемым |
| B6 | Сигнатуру **не пинить** жёстко, оставить `(*args, **kwargs)` + голый `super` | Метод зовётся сериализатором на **каждый пост**; `ArgumentError` = 500 на всех страницах тем. Дрейф ловится спекой, сверяющей сигнатуру ядра, а не падением в проде |
| — | `solved_pm_enabled=false` = **жёсткий запрет** solved во всех PM (не «плагин ничего не делает») | Поведение v0.2.0, зафиксировано ТЗ. Задокументировано и покрыто тестом. **Спорно**, см. п.7 |
| — | Warn кэшируется per-Guardian (= per-request) | Иначе N постов в теме = N одинаковых строк в логе |

---

## 5. Runbook: проверка на стейджинге

### 5.1. Доступ

| | |
|---|---|
| SSH | `ssh testportal` |
| Discourse | docker-контейнер **`app`** |
| Каталог плагина | `/var/www/discourse/plugins/wb-allow-solved-pms` (git-клон) |
| Веб | `https://discourse-sandbox.hq.wirenboard.com`, за nginx Basic Auth — логин/пароль у владельца, **в файлы/коммиты не класть** |

```bash
scp myscript.rb testportal:/tmp/
ssh testportal "sudo docker cp /tmp/myscript.rb app:/tmp/ && \
  sudo docker exec -u discourse -w /var/www/discourse app bin/rails runner /tmp/myscript.rb"
```

### 5.2. ⚠️ Что нужно знать до того, как что-то запускать

1. **`disable_emails = "no"` — стейджинг шлёт настоящую почту.** Тестовые данные создавать
   **только прямым ActiveRecord**, ни в коем случае не `PostCreator`: он дёргает `PostAlerter` →
   нотификации → **письма живым людям** (в группе `support` 74 участника, и PM в инбокс
   нотифицирует их всех). Прямой AR не ставит ни одной джобы.

   > Group SMTP тут ни при чём: у `support` на стейджинге `smtp_enabled=false`. Опасны именно
   > обычные нотификации. На проде SMTP у группы может быть включён — тогда рисков только больше.
2. **`RateLimiter.disable`** — свежие юзеры упираются в `limit_topics_per_day` на
   `Topic#after_create`. Флаг процесс-локальный: действует только на runner, не на unicorn.
3. **rspec на порталах нет.** Контейнер `app` — production-образ, тестовых гемов нет.
   Спеки гоняются только в dev-чекауте: `bin/rake plugin:spec[wb-allow-solved-pms]`.
4. **Группа 41 `wb-employees` имеет `grant_trust_level = 4`** — добавление юзера в неё молча
   поднимает ему TL до 4 (и, соответственно, членство в группе 14 `trust_level_4`). Легко
   принять за баг прав при чтении матрицы.
5. **`bin/rails runner` грузит плагин с диска заново.** Значит, после `docker cp` можно сразу
   гонять матрицу — рестарт unicorn нужен только чтобы обновить **веб**.
6. **Правки, залитые `docker cp`, исчезают при rebuild** — `app.yml` клонирует репу заново из
   GitHub main. Durable только то, что запушено.
7. **Прод не трогать** — ни кода, ни настроек.

### 5.3. Быстрый цикл правка → проверка (без rebuild)

```bash
# А: залить файл прямо в контейнер (быстро, без push)
scp plugin.rb testportal:/tmp/
ssh testportal "sudo docker cp /tmp/plugin.rb app:/var/www/discourse/plugins/wb-allow-solved-pms/plugin.rb"

# Б: durable — запушить в main и подтянуть в контейнере
ssh testportal "sudo docker exec app bash -c 'cd /var/www/discourse/plugins/wb-allow-solved-pms && \
  git -c safe.directory=/var/www/discourse/plugins/wb-allow-solved-pms fetch origin && \
  git -c safe.directory=/var/www/discourse/plugins/wb-allow-solved-pms reset --hard origin/main'"

# обновить веб (секунды, НЕ rebuild). Discourse поднимается ~30-60 с, пока отдаёт 502/503
ssh testportal "sudo docker exec app sv restart unicorn"
ssh testportal "sudo docker exec app curl -s -o /dev/null -w '%{http_code}\n' http://localhost/srv/status"
```

`./launcher rebuild app` **не запускать** — полный даунтайм и не нужен: плагин чисто рубишный,
без JS-ассетов.

### 5.4. Скрипт матрицы прав

Идемпотентный: можно гонять до и после фикса на одних и тех же данных и потом просто
сдиффать вывод. Настройки снимаются в snapshot и восстанавливаются в `ensure`.

<details>
<summary><code>wb_solved_matrix.rb</code></summary>

```ruby
# frozen_string_literal: true
#
# Permission matrix for wb-allow-solved-pms, run against real staging data.
#
# Test data is created with plain ActiveRecord on purpose -- NOT PostCreator --
# so that no job is ever enqueued (staging has disable_emails=no, and the support
# group has SMTP; PostAlerter would send real mail to real people).
#
# Idempotent: safe to run repeatedly. Companion cleanup: wb_solved_cleanup.rb

PREFIX = "wbtest_solvedpm"
SUPPORT_GROUP_ID = 44 # support
OTHER_GROUP_ID = 41 # wb-employees

# Brand-new users trip limit_topics_per_day on Topic#after_create.
# This flag is process-local: it only affects this runner, never the portal's unicorn.
RateLimiter.disable

def user!(suffix, admin: false, moderator: false, trust_level: TrustLevel[1])
  username = "#{PREFIX}_#{suffix}"
  found = User.find_by(username_lower: username.downcase)
  return found if found

  u =
    User.new(
      username: username,
      name: username,
      email: "#{username}@example.com",
      password: SecureRandom.hex(24),
      trust_level: trust_level,
      admin: admin,
      moderator: moderator,
      active: true,
      approved: true,
    )
  u.save!(validate: false)
  u.user_option&.update_columns(email_digests: false, email_level: 2) # never
  u.reload
end

def pm!(slug, owner:, allowed_users:, group_ids:, reply_by:)
  title = "#{PREFIX} #{slug}"
  t = Topic.where(title: title).first

  if t
    # keep participants in sync on re-runs
    ([owner] + allowed_users).map(&:id).uniq.each do |uid|
      TopicAllowedUser.find_or_create_by!(topic_id: t.id, user_id: uid)
    end
    group_ids.each { |gid| TopicAllowedGroup.find_or_create_by!(topic_id: t.id, group_id: gid) }
    return t
  end

  t =
    Topic.new(
      title: title,
      user_id: owner.id,
      archetype: Archetype.private_message,
      subtype: TopicSubtype.user_to_user,
      category_id: nil,
    )
  t.save!(validate: false)

  ([owner] + allowed_users).map(&:id).uniq.each do |uid|
    TopicAllowedUser.create!(topic_id: t.id, user_id: uid)
  end
  group_ids.each { |gid| TopicAllowedGroup.create!(topic_id: t.id, group_id: gid) }

  [[1, owner, "Opening post for #{slug}. This is throwaway test data."],
   [2, reply_by, "Reply post for #{slug}. This is the candidate solution."]].each do |n, u, raw|
    p = Post.new(
      topic_id: t.id,
      user_id: u.id,
      raw: raw,
      cooked: "<p>#{raw}</p>",
      post_number: n,
      sort_order: n,
      post_type: Post.types[:regular],
    )
    p.save!(validate: false)
  end
  t.update_columns(posts_count: 2, highest_post_number: 2, last_posted_at: Time.zone.now)
  t.reload
end

# --- set a site setting even if it would fail the group_list validator ------------
def force_setting(name, value)
  SiteSetting.public_send("#{name}=", value)
rescue StandardError
  SiteSetting.provider.save(name.to_s, value, SiteSetting.types[:group_list])
  SiteSetting.refresh!
end

# --- setup -----------------------------------------------------------------------
staff = user!("staff", moderator: true)
support = user!("support")
tl4 = user!("tl4", trust_level: TrustLevel[4])
owner = user!("owner")
bystander = user!("bystander")
outsider = user!("outsider")

Group.find(SUPPORT_GROUP_ID).add(support) unless support.group_ids.include?(SUPPORT_GROUP_ID)
Group.find(OTHER_GROUP_ID).add(bystander) unless bystander.group_ids.include?(OTHER_GROUP_ID)

support_pm =
  pm!(
    "support-inbox-pm",
    owner: owner,
    allowed_users: [bystander, tl4, staff],
    group_ids: [SUPPORT_GROUP_ID],
    reply_by: staff,
  )
other_pm =
  pm!(
    "other-group-inbox-pm",
    owner: owner,
    allowed_users: [staff, tl4],
    group_ids: [OTHER_GROUP_ID],
    reply_by: staff,
  )
dm_pm = pm!("one-to-one-pm", owner: owner, allowed_users: [staff], group_ids: [], reply_by: staff)

TOPICS = { "support_pm" => support_pm, "other_pm" => other_pm, "dm_pm" => dm_pm }.freeze
ACTORS = {
  "staff" => staff,
  "support" => support,
  "tl4" => tl4,
  "owner" => owner,
  "bystander" => bystander,
  "outsider" => outsider,
}.freeze

VARIANTS = [
  { key: "V1-staging-as-is", target: "44", actor: "1|3|44", owner: true, personal: false },
  { key: "V2-names", target: "support", actor: "staff|support", owner: true, personal: false },
  { key: "V3-mixed-prodlike", target: "support|44", actor: "staff|44|1|3|14", owner: true, personal: false },
  { key: "V4-empty-target", target: "", actor: "1|3|44", owner: true, personal: false },
  { key: "V5-empty-target-personal-on", target: "", actor: "1|3|44", owner: true, personal: true },
  { key: "V6-unresolvable-target", target: "no_such_group_xyz", actor: "1|3|44", owner: true, personal: false },
  { key: "V7-target-and-personal-on", target: "44", actor: "1|3|44", owner: true, personal: true },
  { key: "V8-owner-off", target: "44", actor: "1|3|44", owner: false, personal: false },
].freeze

snapshot = {
  target: SiteSetting.solved_pm_target_groups,
  actor: SiteSetting.solved_pm_actor_groups,
  owner: SiteSetting.solved_pm_allow_topic_owner,
  personal: SiteSetting.solved_pm_allow_personal_messages,
}

puts "plugin_version=#{Discourse.plugins.find { |p| p.name == 'wb-allow-solved-pms' }&.metadata&.version}"
puts "patched=#{Guardian.ancestors.map(&:to_s).grep(/WbAllowSolvedPms/).any?}"
puts

begin
  VARIANTS.each do |v|
    force_setting(:solved_pm_target_groups, v[:target])
    force_setting(:solved_pm_actor_groups, v[:actor])
    SiteSetting.solved_pm_allow_topic_owner = v[:owner]
    SiteSetting.solved_pm_allow_personal_messages = v[:personal]

    resolved =
      if defined?(::WbAllowSolvedPms) && ::WbAllowSolvedPms.respond_to?(:group_ids_from_setting)
        t = ::WbAllowSolvedPms.group_ids_from_setting(SiteSetting.solved_pm_target_groups)
        a = ::WbAllowSolvedPms.group_ids_from_setting(SiteSetting.solved_pm_actor_groups)
        "target->#{t.inspect} actor->#{a.inspect}"
      else
        g = Guardian.new(Discourse.system_user)
        t = g.send(:group_ids_from_setting, SiteSetting.solved_pm_target_groups)
        a = g.send(:group_ids_from_setting, SiteSetting.solved_pm_actor_groups)
        "target->#{t.inspect} actor->#{a.inspect}"
      end

    puts "# #{v[:key]}  target=#{v[:target].inspect} actor=#{v[:actor].inspect} " \
           "owner=#{v[:owner]} personal=#{v[:personal]}"
    puts "#   resolved: #{resolved}"

    TOPICS.each do |tname, topic|
      post = Post.find_by(topic_id: topic.id, post_number: 2)
      ACTORS.each do |aname, actor|
        g = Guardian.new(actor.reload)
        see = g.can_see?(topic)
        accept =
          begin
            g.can_accept_answer?(topic, post)
          rescue StandardError => e
            "ERR:#{e.class}"
          end
        puts format("%-28s | %-10s | %-9s | see=%-5s | accept=%s", v[:key], tname, aname, see, accept)
      end
    end
    puts
  end
ensure
  force_setting(:solved_pm_target_groups, snapshot[:target])
  force_setting(:solved_pm_actor_groups, snapshot[:actor])
  SiteSetting.solved_pm_allow_topic_owner = snapshot[:owner]
  SiteSetting.solved_pm_allow_personal_messages = snapshot[:personal]
  puts "settings restored: #{snapshot.inspect}"
end
```
</details>

**Как диффать до/после** (144 строки, сравнение по ключу вариант_топик_актор):

```bash
join -t'|' -j 1 \
  <(grep ' | ' before.txt | awk -F'|' '{gsub(/ /,"",$1);gsub(/ /,"",$2);gsub(/ /,"",$3); print $1"_"$2"_"$3"|"$5}' | sort) \
  <(grep ' | ' after.txt  | awk -F'|' '{gsub(/ /,"",$1);gsub(/ /,"",$2);gsub(/ /,"",$3); print $1"_"$2"_"$3"|"$5}' | sort) \
  | awk -F'|' '$2!=$3 {printf "%-55s before:%-14s after:%s\n", $1, $2, $3}' | sort
```

### 5.5. Скрипт уборки

**Гонять обязательно** — тестовые юзеры остаются в реальной группе `support`.

<details>
<summary><code>wb_solved_cleanup.rb</code></summary>

```ruby
# frozen_string_literal: true
# Removes everything wb_solved_matrix.rb created on staging.

PREFIX = "wbtest_solvedpm"

Topic.unscoped.where("title LIKE ?", "#{PREFIX}%").each do |t|
  puts "deleting topic #{t.id} #{t.title.inspect}"
  Post.unscoped.where(topic_id: t.id).delete_all
  TopicAllowedUser.where(topic_id: t.id).delete_all
  TopicAllowedGroup.where(topic_id: t.id).delete_all
  PostSearchData.where(post_id: Post.unscoped.where(topic_id: t.id).select(:id)).delete_all
  TopicSearchData.where(topic_id: t.id).delete_all
  UserAction.where(target_topic_id: t.id).delete_all
  Notification.where(topic_id: t.id).delete_all
  t.delete
end

User.where("username_lower LIKE ?", "#{PREFIX.downcase}%").each do |u|
  puts "destroying user #{u.id} #{u.username}"
  u.update_columns(admin: false, moderator: false)
  begin
    UserDestroyer.new(Discourse.system_user).destroy(u, delete_posts: true, context: "wbtest cleanup")
  rescue StandardError => e
    puts "  UserDestroyer failed (#{e.class}: #{e.message}) -- falling back to delete"
    u.delete
  end
end

puts
puts "leftover topics: #{Topic.unscoped.where('title LIKE ?', "#{PREFIX}%").count}"
puts "leftover users:  #{User.where('username_lower LIKE ?', "#{PREFIX.downcase}%").count}"
puts
puts "final settings:"
%w[
  solved_pm_enabled
  solved_pm_target_groups
  solved_pm_actor_groups
  solved_pm_allow_topic_owner
  solved_pm_allow_personal_messages
].each { |s| puts format("  %-36s = %p", s, SiteSetting.public_send(s)) }
```
</details>

---

## 6. Результат прогона 2026-07-16 (0.2.0 → 0.3.0)

Состояние стейджинга: `solved_enabled=true`, `solved_pm_enabled=true`,
`target="44"`, `actor="1|3|44"`, `allow_topic_owner=true`, `allow_personal_messages=false`.
Группы: `0=everyone 1=admins 2=moderators 3=staff 10..14=trust_level_0..4 41=wb-employees 44=support`.

**Резолв (V1, настройки как на стейджинге):** `target->[] actor->[]` → `target->[44] actor->[1,3,44]`.

Из 144 строк изменились 17, все в ожидаемую сторону:

| Вариант | Топик | Актор | До | После | Что показывает |
|---|---|---|---|---|---|
| V1 | other_pm | staff | `true` | **`false`** | **B2**: fail-open снят — PM в чужой инбокс больше не eligible |
| V1 | other_pm | owner | `true` | **`false`** | то же для автора топика |
| V1 | support_pm | support | `false` | **`true`** | **B1**: член `support`, не staff, наконец может |
| V6 | support_pm, other_pm × staff, owner | | `true` | **`false`** | **B2**: нерезолвящийся target → fail closed (4 строки) |
| V3 | support_pm × support, tl4, bystander | | `false` | **`true`** | actor `"staff\|44\|1\|3\|14"` резолвится в `[44,1,3,14]` |
| V4/V5/V7/V8 | support_pm | support | `false` | **`true`** | actor `"1\|3\|44"` резолвится |
| V8 | other_pm | staff | `true` | **`false`** | fail-open снят и при `owner=false` |

**B2 отдельно проверен точечно:** при `target="no_such_group_xyz"` → `accept=false`, и в лог
уходит **ровно одна** строка warn на два вызова одного Guardian:

```
[wb-allow-solved-pms] SiteSetting.solved_pm_target_groups = "no_such_group_xyz" matches no
existing group (expected pipe-delimited group ids). Treating it as a misconfiguration:
nothing is granted through this setting.
```

**Про V3 / `bystander`:** строка `V3 | support_pm | bystander: false → true` выглядит как
раздача лишних прав, но это корректно — `bystander` был добавлен в группу 41 `wb-employees`,
у которой `grant_trust_level=4`, поэтому он оказался в группе 14 `trust_level_4`, а V3-шный
actor-список её содержит. Артефакт фикстуры, не плагина (см. п.5.2.4).

### Чего в этом прогоне **нет**

**B5 до/после на стейджинге не показывается** — там он был замаскирован B1. При `target="44"`,
который старый код резолвил в `[]`, работала `else`-ветка, которая 1:1 как раз разрешала:
`V7 | dm_pm | staff` = `true` и до, и после. Чтобы увидеть B5 живьём, нужен вариант
«target именем + personal=true» (старый резолвер имена понимал), которого в матрице нет.

На **проде** B5 был живой: там `target="support|44|3"` старым кодом резолвился по имени в `[44]`,
то есть непустой target отсекал любой 1:1 → включить `allow_personal_messages` было нельзя.
Там же, соответственно, **не было** и fail-open из B2 — это был симптом только стейджинга.

Что фикс B5 работает, видно из after-состояния: при одинаково заданном `target="44"`
`V1 | dm_pm` = `false` (personal=off) против `V7 | dm_pm` = `true` (personal=on) —
1:1 переключается независимо от target-групп. Плюс спеки.

---

## 7. Открытые вопросы

1. **Прод: почистить настройки до его следующего rebuild.** Фикс делает грязные значения
   рабочими, и это **расширяет** права акторов:
   - `actor="staff|44|1|3|14"`: было `[3]` (фактически no-op — staff и так проходят),
     стало `[44,1,3,14]` → **все TL4 получают право закрывать решения**;
   - `target="support|44|3"`: было `[44]`, стало `[44,3]` → PM в staff-инбокс тоже eligible.

   Прод клонирует из GitHub main, так что 0.3.0 приедет на первом же rebuild.
2. **Нужен ли плагин вообще** — ядро умеет `allow_solved_in_groups` (п.1). Стоит сравнить
   гейты плагина с потребностью; возможно, хватит ядра.
3. **`solved_pm_enabled=false` = запрет solved во всех PM**, а не «плагин выключен и не мешает».
   Семантика спорная: выключенный плагин глушит и штатный `allow_solved_in_groups` ядра.
4. **Спеки не гонялись ни разу** — ни на порталах (нет rspec), ни локально (нет dev-чекаута).
   Написаны по конвенциям bundled `discourse-solved` из этого же контейнера, синтаксис
   проверен `ruby -c`. Первый реальный прогон в dev/CI может вскрыть мелочи.
5. **Перенос репы в орг `wirenboard`** (скилл `wb-repo-to-org`) — тогда обновить URL в `app.yml`
   на обоих порталах. Отдельная задача.
