# frozen_string_literal: true

require "tiny_color"
require_relative "../mecha_tenant"

class String
  def dark_grey
    respond_to?(:grey) ? grey : self
  end unless method_defined?(:dark_grey)

  def dark_gray
    respond_to?(:gray) ? gray : self
  end unless method_defined?(:dark_gray)
end

desc "Print all models and controller actions with their MechaTenant isolation controls"
task mecha_tenant: :environment do
  auditor = MechaTenant::Auditor::Static.new
  result = auditor.audit
  colors = MechaTenant.configuration.debug_colorization

  colorize = ->(text, key) {
    color = colors[key]
    if color && text.respond_to?(color)
      text.send(color)
    else
      text
    end
  }

  puts "=== Model Tenancy Registry ==="
  all_model_names = result.mapped_models.map { |m| m[:model] } + result.unmapped_models
  max_model_len = [all_model_names.map(&:length).max || 5, 5].max
  max_class_len = 14

  puts sprintf("%-#{max_model_len}s  %-#{max_class_len}s  %s", "Model", "Classification", "Ownership")

  result.mapped_models.each do |entry|
    cls_sym = entry[:classification]
    padded_model = sprintf("%-#{max_model_len}s", entry[:model])
    padded_class = sprintf("%-#{max_class_len}s", cls_sym.to_s.upcase)
    ownership = entry[:ownership] || (cls_sym == :global ? "(global/system)" : "-")

    puts sprintf(
      "%s  %s  %s",
      colorize.call(padded_model, cls_sym),
      colorize.call(padded_class, cls_sym),
      ownership
    )
  end

  result.unmapped_models.each do |model_name|
    padded_model = sprintf("%-#{max_model_len}s", model_name)
    padded_class = sprintf("%-#{max_class_len}s", "UNMAPPED")
    puts sprintf(
      "%s  %s  %s",
      colorize.call(padded_model, :unmapped),
      colorize.call(padded_class, :unmapped),
      "MISSING FROM config/mecha_tenant.yml"
    )
  end

  puts "\n=== Controller Action Tenancy Enforcement ==="
  audits = result.action_audits
  max_verb_len = [audits.map { |a| a.verb.to_s.length }.max || 4, 4].max
  max_path_len = [audits.map { |a| a.path.to_s.length }.max || 11, 11].max
  max_target_len = [audits.map { |a| "#{a.controller}##{a.action}".length }.max || 17, 17].max
  max_status_len = 9

  puts sprintf(
    "%-#{max_verb_len}s  %-#{max_path_len}s  %-#{max_target_len}s  %-#{max_status_len}s  %s",
    "Verb",
    "URI Pattern",
    "Controller#Action",
    "Status",
    "Scoping / Reason"
  )

  audits.each do |a|
    padded_verb = sprintf("%-#{max_verb_len}s", a.verb)
    padded_path = sprintf("%-#{max_path_len}s", a.path)
    padded_target = sprintf("%-#{max_target_len}s", "#{a.controller}##{a.action}")
    padded_status = sprintf("%-#{max_status_len}s", a.status.to_s.upcase)

    detail = case a.status
    when :skipped
      "SKIP: #{a.skip_reason}"
    when :violation
      "VIOLATION"
    else
      a.scopes_used.any? ? a.scopes_used.join(", ") : "(no model queries)"
    end

    puts sprintf(
      "%s  %s  %s  %s  %s",
      padded_verb,
      colorize.call(padded_path, a.status),
      padded_target,
      colorize.call(padded_status, a.status),
      detail
    )
  end
end

namespace :mecha_tenant do
  namespace :verify do
    desc "Statically verify model tenancy registry parity and strict controller lookup scoping"
    task static: :environment do
      puts "Running MechaTenant static model & controller AST audit..."
      auditor = MechaTenant::Auditor::Static.new
      result = auditor.audit

      tenant_count = result.mapped_models.count { |m| m[:classification] == :tenant }
      global_count = result.mapped_models.count { |m| m[:classification] == :global }
      enforced_count = result.action_audits.count { |a| a.status == :enforced }
      skipped_count = result.action_audits.count { |a| a.status == :skipped }

      puts "  -> #{result.mapped_models.size} models registered (#{tenant_count} tenant, #{global_count} global)"
      puts "  -> #{result.action_audits.size} controller routes audited (#{enforced_count} enforced, #{skipped_count} explicitly skipped)"

      if result.unmapped_models.any?
        puts "\nERROR: Found #{result.unmapped_models.size} unmapped model(s) missing from config/mecha_tenant.yml:".light_red
        result.unmapped_models.each { |m| puts "  - #{m}" }
      end

      if result.dead_models.any?
        puts "\nERROR: Found #{result.dead_models.size} dead/stale model(s) in config/mecha_tenant.yml:".light_red
        result.dead_models.each { |m| puts "  - #{m}" }
      end

      if result.missing_scopes.any?
        puts "\nERROR: Found #{result.missing_scopes.size} model scope configuration error(s):".light_red
        result.missing_scopes.each { |err| puts "  - #{err}" }
      end

      if result.dead_skip_rules.any?
        puts "\nERROR: Found #{result.dead_skip_rules.size} dead skip_tenant_enforcement! rule(s):".light_red
        result.dead_skip_rules.each { |dr| puts "  - #{dr[:file]}: #{dr[:message]}" }
      end

      if result.violations.any?
        puts "\nERROR: Found #{result.violations.size} unscoped model reference violation(s) in controllers:".light_red
        result.violations.each do |v|
          puts "  - #{v.file}:#{v.line} [#{v.controller}##{v.method_name}] #{v.message}"
          puts "      #{v.snippet}"
        end
      end

      if result.success?
        puts "\n✓ Static tenant isolation audit passed: 0 unmapped models, 0 dead rules, 0 controller violations.".green
      else
        abort("\n✗ Static tenant isolation audit failed. Please resolve the errors above.")
      end
    end

    desc "Run behavioral cross-tenant scope and IDOR route matrix test suite"
    task behavioral: :environment do
      puts "Running MechaTenant behavioral cross-tenant isolation matrix test suite..."
      matrix_test_path = File.expand_path("../mecha_tenant/matrix_test.rb", __dir__)
      system({ "MECHA_MATRIX_STANDALONE" => "1" }, "bin/rails", "test", matrix_test_path) || abort("Behavioral tenant verification failed.")
    end
  end

  desc "Run both static AST/registry verification and behavioral cross-tenant IDOR verification"
  task verify: %w[verify:static verify:behavioral]
end
