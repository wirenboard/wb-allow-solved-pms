# frozen_string_literal: true

require "rails_helper"

describe WbAllowSolvedPms::GuardianPatch do
  fab!(:support_group) { Fabricate(:group, name: "support") }
  fab!(:sales_group) { Fabricate(:group, name: "sales") }
  fab!(:actor_group) { Fabricate(:group, name: "agents") }

  fab!(:owner) { Fabricate(:user, refresh_auto_groups: true) }
  fab!(:agent) { Fabricate(:user, refresh_auto_groups: true) }
  fab!(:bystander) { Fabricate(:user, refresh_auto_groups: true) }
  fab!(:outsider) { Fabricate(:user, refresh_auto_groups: true) }
  fab!(:admin) { Fabricate(:admin, refresh_auto_groups: true) }

  # Group inbox PM addressed to `support`, started by `owner`.
  fab!(:pm) { Fabricate(:group_private_message_topic, user: owner, recipient_group: support_group) }
  fab!(:pm_op) { Fabricate(:post, topic: pm, user: owner) }
  fab!(:pm_reply) { Fabricate(:post, topic: pm, user: agent) }

  # Group inbox PM addressed to a *different* inbox.
  fab!(:other_pm) do
    Fabricate(:group_private_message_topic, user: owner, recipient_group: sales_group)
  end
  fab!(:other_pm_op) { Fabricate(:post, topic: other_pm, user: owner) }
  fab!(:other_pm_reply) { Fabricate(:post, topic: other_pm, user: agent) }

  # Strictly 1:1 PM -- exactly two allowed users, no groups.
  fab!(:dm) { Fabricate(:private_message_topic, user: owner, recipient: agent) }
  fab!(:dm_op) { Fabricate(:post, topic: dm, user: owner) }
  fab!(:dm_reply) { Fabricate(:post, topic: dm, user: agent) }

  before do
    SiteSetting.solved_enabled = true
    SiteSetting.solved_pm_enabled = true
    SiteSetting.solved_pm_target_groups = support_group.id.to_s
    SiteSetting.solved_pm_actor_groups = ""
    SiteSetting.solved_pm_allow_topic_owner = false
    SiteSetting.solved_pm_allow_personal_messages = false

    # PMs are only visible to their participants; group membership is what lets
    # these two see the group inboxes at all.
    [support_group, sales_group].each do |g|
      g.add(agent)
      g.add(bystander)
    end
  end

  describe "non-PM topics" do
    fab!(:topic, :topic_with_op)
    fab!(:reply) { Fabricate(:post, topic: topic) }

    it "are left entirely to core, even when this plugin is switched off" do
      SiteSetting.solved_pm_enabled = false
      SiteSetting.allow_solved_on_all_topics = true

      expect(Guardian.new(admin).can_accept_answer?(topic, reply)).to eq(true)
    end

    it "still obey core's own rules" do
      SiteSetting.allow_solved_on_all_topics = false

      expect(Guardian.new(admin).can_accept_answer?(topic, reply)).to eq(false)
    end
  end

  describe "feature gates" do
    it "denies when solved_enabled is off" do
      SiteSetting.solved_enabled = false

      expect(Guardian.new(admin).can_accept_answer?(pm, pm_reply)).to eq(false)
    end

    # Deliberate: switching the plugin off blocks Solved in *every* PM, including ones
    # core would have allowed via allow_solved_in_groups / allow_solved_on_all_topics.
    it "denies every PM when solved_pm_enabled is off" do
      SiteSetting.solved_pm_enabled = false
      SiteSetting.allow_solved_on_all_topics = true

      expect(Guardian.new(admin).can_accept_answer?(pm, pm_reply)).to eq(false)
    end

    it "denies anonymous users" do
      expect(Guardian.new.can_accept_answer?(pm, pm_reply)).to eq(false)
    end
  end

  describe "guardrails" do
    it "never accepts the first post" do
      expect(Guardian.new(admin).can_accept_answer?(pm, pm_op)).to eq(false)
    end

    it "rejects whispers" do
      pm_reply.update!(post_type: Post.types[:whisper])

      expect(Guardian.new(admin).can_accept_answer?(pm, pm_reply)).to eq(false)
    end

    it "rejects small actions" do
      pm_reply.update!(post_type: Post.types[:small_action])

      expect(Guardian.new(admin).can_accept_answer?(pm, pm_reply)).to eq(false)
    end

    it "rejects deleted posts" do
      pm_reply.trash!(admin)

      expect(Guardian.new(admin).can_accept_answer?(pm, pm_reply)).to eq(false)
    end

    it "rejects closed topics" do
      pm.update!(closed: true)

      expect(Guardian.new(admin).can_accept_answer?(pm, pm_reply)).to eq(false)
    end

    it "rejects archived topics" do
      pm.update!(archived: true)

      expect(Guardian.new(admin).can_accept_answer?(pm, pm_reply)).to eq(false)
    end

    it "rejects posts by the system user" do
      pm_reply.update_columns(user_id: Discourse.system_user.id)

      expect(Guardian.new(admin).can_accept_answer?(pm, pm_reply.reload)).to eq(false)
    end

    it "rejects a post that belongs to another topic" do
      expect(Guardian.new(admin).can_accept_answer?(pm, other_pm_reply)).to eq(false)
    end

    it "rejects a PM the user cannot see" do
      expect(Guardian.new(outsider).can_accept_answer?(pm, pm_reply)).to eq(false)
    end
  end

  describe "which PM topics are eligible" do
    context "with solved_pm_target_groups configured by id (B1)" do
      before { SiteSetting.solved_pm_target_groups = support_group.id.to_s }

      it "allows the configured inbox and only that inbox" do
        expect(Guardian.new(admin).can_accept_answer?(pm, pm_reply)).to eq(true)
        expect(Guardian.new(admin).can_accept_answer?(other_pm, other_pm_reply)).to eq(false)
      end
    end

    context "with solved_pm_target_groups configured by legacy name (B1)" do
      before { SiteSetting.solved_pm_target_groups = "support" }

      it "still resolves the inbox" do
        expect(Guardian.new(admin).can_accept_answer?(pm, pm_reply)).to eq(true)
        expect(Guardian.new(admin).can_accept_answer?(other_pm, other_pm_reply)).to eq(false)
      end
    end

    context "with a mixed name/id target list (B1)" do
      before { SiteSetting.solved_pm_target_groups = "support|#{sales_group.id}" }

      it "resolves both halves" do
        expect(Guardian.new(admin).can_accept_answer?(pm, pm_reply)).to eq(true)
        expect(Guardian.new(admin).can_accept_answer?(other_pm, other_pm_reply)).to eq(true)
      end
    end

    context "with solved_pm_target_groups empty" do
      before { SiteSetting.solved_pm_target_groups = "" }

      # Documented behaviour: no target list means "every group inbox".
      it "allows every group inbox" do
        expect(Guardian.new(admin).can_accept_answer?(pm, pm_reply)).to eq(true)
        expect(Guardian.new(admin).can_accept_answer?(other_pm, other_pm_reply)).to eq(true)
      end

      it "still does not allow 1:1 messages by itself" do
        expect(Guardian.new(admin).can_accept_answer?(dm, dm_reply)).to eq(false)
      end
    end

    context "with solved_pm_target_groups set but unresolvable (B2)" do
      before { SiteSetting.solved_pm_target_groups = "no_such_group" }

      it "fails closed instead of allowing every group inbox" do
        expect(Guardian.new(admin).can_accept_answer?(pm, pm_reply)).to eq(false)
        expect(Guardian.new(admin).can_accept_answer?(other_pm, other_pm_reply)).to eq(false)
      end

      it "warns so the misconfiguration is visible" do
        allow(Rails.logger).to receive(:warn)

        Guardian.new(admin).can_accept_answer?(pm, pm_reply)

        expect(Rails.logger).to have_received(:warn).with(
          /solved_pm_target_groups .* matches no existing group/m,
        ).at_least(:once)
      end
    end

    describe "1:1 personal messages (B5)" do
      it "are ineligible while solved_pm_allow_personal_messages is off" do
        expect(Guardian.new(admin).can_accept_answer?(dm, dm_reply)).to eq(false)
      end

      it "are eligible when the setting is on, even though target groups are configured" do
        SiteSetting.solved_pm_target_groups = support_group.id.to_s
        SiteSetting.solved_pm_allow_personal_messages = true

        expect(Guardian.new(admin).can_accept_answer?(dm, dm_reply)).to eq(true)
      end

      it "do not make non-target group inboxes eligible" do
        SiteSetting.solved_pm_allow_personal_messages = true

        expect(Guardian.new(admin).can_accept_answer?(other_pm, other_pm_reply)).to eq(false)
      end

      it "cover strictly two participants only" do
        SiteSetting.solved_pm_allow_personal_messages = true
        TopicAllowedUser.create!(topic_id: dm.id, user_id: bystander.id)

        expect(Guardian.new(admin).can_accept_answer?(dm, dm_reply)).to eq(false)
      end
    end
  end

  describe "who may mark a solution" do
    # B4: resolved as "staff always may"; solved_pm_actor_groups can only ever add people.
    it "always allows staff, even when the actor groups exclude them" do
      SiteSetting.solved_pm_actor_groups = actor_group.id.to_s

      expect(Guardian.new(admin).can_accept_answer?(pm, pm_reply)).to eq(true)
    end

    it "allows members of the actor groups (B1)" do
      SiteSetting.solved_pm_actor_groups = actor_group.id.to_s
      actor_group.add(agent)

      expect(Guardian.new(agent).can_accept_answer?(pm, pm_reply)).to eq(true)
    end

    it "allows actor groups given by legacy name (B1)" do
      SiteSetting.solved_pm_actor_groups = "agents"
      actor_group.add(agent)

      expect(Guardian.new(agent).can_accept_answer?(pm, pm_reply)).to eq(true)
    end

    it "denies participants who are in none of the actor groups" do
      SiteSetting.solved_pm_actor_groups = actor_group.id.to_s

      expect(Guardian.new(bystander).can_accept_answer?(pm, pm_reply)).to eq(false)
    end

    it "never lets group 0 / everyone through the actor list (B3)" do
      SiteSetting.solved_pm_actor_groups = "0|#{actor_group.id}"

      # bystander can see the PM (member of support) but is in no actor group;
      # if 0 were honoured as `everyone`, this would be true.
      expect(Guardian.new(bystander).can_accept_answer?(pm, pm_reply)).to eq(false)

      actor_group.add(bystander)
      expect(Guardian.new(bystander).can_accept_answer?(pm, pm_reply)).to eq(true)
    end

    it "denies everyone but staff when the actor groups are unresolvable (B2)" do
      SiteSetting.solved_pm_actor_groups = "no_such_group"
      actor_group.add(agent)

      expect(Guardian.new(agent).can_accept_answer?(pm, pm_reply)).to eq(false)
      expect(Guardian.new(admin).can_accept_answer?(pm, pm_reply)).to eq(true)
    end

    it "honours solved_pm_allow_topic_owner" do
      SiteSetting.solved_pm_allow_topic_owner = true
      expect(Guardian.new(owner).can_accept_answer?(pm, pm_reply)).to eq(true)

      SiteSetting.solved_pm_allow_topic_owner = false
      expect(Guardian.new(owner).can_accept_answer?(pm, pm_reply)).to eq(false)
    end

    it "does not treat the topic owner as an actor in a non-target inbox" do
      SiteSetting.solved_pm_allow_topic_owner = true

      expect(Guardian.new(owner).can_accept_answer?(other_pm, other_pm_reply)).to eq(false)
    end
  end

  describe "setting resolution caching" do
    it "does not serve a stale resolution after the setting changes" do
      guardian = Guardian.new(admin)
      expect(guardian.can_accept_answer?(pm, pm_reply)).to eq(true)

      SiteSetting.solved_pm_target_groups = sales_group.id.to_s

      expect(guardian.can_accept_answer?(pm, pm_reply)).to eq(false)
    end
  end

  describe "call shapes (B6)" do
    it "matches the core signature it prepends" do
      skip "discourse-solved not loaded" unless defined?(::DiscourseSolved::GuardianExtensions)

      expect(
        ::DiscourseSolved::GuardianExtensions.instance_method(:can_accept_answer?).parameters,
      ).to eq([%i[req topic], %i[req post]])
    end

    it "answers the same for the positional and the keyword form" do
      expect(Guardian.new(admin).can_accept_answer?(pm, pm_reply)).to eq(true)
      expect(Guardian.new(admin).can_accept_answer?(topic: pm, post: pm_reply)).to eq(true)
    end

    it "answers the same for both forms when denying" do
      expect(Guardian.new(bystander).can_accept_answer?(pm, pm_reply)).to eq(false)
      expect(Guardian.new(bystander).can_accept_answer?(topic: pm, post: pm_reply)).to eq(false)
    end

    it "hands a nil topic to core rather than guessing" do
      expect(Guardian.new(admin).can_accept_answer?(nil, pm_reply)).to eq(false)
    end
  end

  describe "can_unaccept_answer?" do
    it "is gated by the same PM rules" do
      SiteSetting.solved_pm_actor_groups = actor_group.id.to_s
      actor_group.add(agent)
      expect(Guardian.new(agent).can_unaccept_answer?(pm, pm_reply)).to eq(true)

      SiteSetting.solved_pm_target_groups = sales_group.id.to_s
      expect(Guardian.new(agent).can_unaccept_answer?(pm, pm_reply)).to eq(false)
    end
  end
end
