# frozen_string_literal: true

module MechaTenant
  module Auditor
    class Prober
      ScopeFailure = Struct.new(:model, :message, keyword_init: true)
      RouteFailure = Struct.new(:route, :target_model, :expected, :actual, :message, keyword_init: true)

      Result = Struct.new(:scoped_models_count, :probed_routes_count, :scope_failures, :route_failures, keyword_init: true) do
        def success?
          scope_failures.empty? && route_failures.empty?
        end

        def failures
          scope_failures + route_failures
        end
      end

      def initialize(integration_session = nil, registry: MechaTenant.registry, configuration: MechaTenant.configuration)
        @session = integration_session
        @registry = registry
        @configuration = configuration
      end

      # Verify that every registered tenant model's scope isolates victim records from attacker
      def probe_model_scopes(victim:, attacker:, victim_records:)
        scope_failures = []
        scoped_count = 0
        normalized_records = normalize_records_map(victim_records)

        @registry.tenant_models.each_key do |model_name|
          res = probe_single_model_scope(
            model_name,
            victim: victim,
            attacker: attacker,
            victim_records: normalized_records
          )
          scoped_count += res.scoped_models_count
          scope_failures.concat(res.scope_failures)
        end

        Result.new(
          scoped_models_count: scoped_count,
          probed_routes_count: 0,
          scope_failures: scope_failures,
          route_failures: []
        )
      end

      def probe_single_model_scope(model_name, victim:, attacker:, victim_records:)
        scope_failures = []
        normalized_records = normalize_records_map(victim_records)
        record = normalized_records[model_name.to_s]

        if record.nil?
          scope_failures << ScopeFailure.new(
            model: model_name.to_s,
            message: "Missing victim test record for registered tenant model '#{model_name}'"
          )
        else
          begin
            victim_scope = @registry.scope_for(model_name.to_s, victim)
            attacker_scope = @registry.scope_for(model_name.to_s, attacker)

            unless victim_scope.where(id: record.id).exists?
              scope_failures << ScopeFailure.new(
                model: model_name.to_s,
                message: "Victim scope for #{model_name} did not include victim's own record (id=#{record.id})"
              )
            end

            if attacker_scope.where(id: record.id).exists?
              scope_failures << ScopeFailure.new(
                model: model_name.to_s,
                message: "CROSS-TENANT LEAK: Attacker scope for #{model_name} included victim's record (id=#{record.id})"
              )
            end
          rescue => e
            scope_failures << ScopeFailure.new(
              model: model_name.to_s,
              message: "Exception evaluating scope for #{model_name}: #{e.class}: #{e.message}"
            )
          end
        end

        Result.new(
          scoped_models_count: 1,
          probed_routes_count: 0,
          scope_failures: scope_failures,
          route_failures: []
        )
      end

      # Dynamically probe all enforced parameterized routes as attacker attempting to access victim's records
      def probe_idor_routes(victim_records:, ui_auth:, api_auth: nil)
        raise ArgumentError, "Integration session is required for route probing" if @session.nil?

        route_failures = []
        probed_count = 0
        normalized_records = normalize_records_map(victim_records)

        enforced_id_audits = self.class.collect_enforced_id_audits(@registry, @configuration)

        enforced_id_audits.each do |audit|
          res = probe_single_idor_route(
            audit,
            victim_records: normalized_records,
            ui_auth: ui_auth,
            api_auth: api_auth
          )
          probed_count += res.probed_routes_count
          route_failures.concat(res.route_failures)
        end

        Result.new(
          scoped_models_count: 0,
          probed_routes_count: probed_count,
          scope_failures: [],
          route_failures: route_failures
        )
      end

      def probe_single_idor_route(audit, victim_records:, ui_auth:, api_auth: nil)
        raise ArgumentError, "Integration session is required for route probing" if @session.nil?

        route_failures = []
        normalized_records = normalize_records_map(victim_records)

        target_model_name = infer_target_model(audit, normalized_records)
        victim_record = target_model_name ? normalized_records[target_model_name] : nil

        target_id = victim_record ? victim_record.id.to_s : "00000000-0000-0000-0000-000000000000"
        snapshot_before = victim_record ? snapshot_record(victim_record) : nil

        path = audit.path.gsub(":id", target_id).gsub(/:[a-zA-Z_]+/, "1")
        is_api = path.start_with?("/api/")

        headers = if is_api && api_auth
          api_auth.call(@session) || {}
        else
          ui_auth.call(@session) || {}
        end

        status = dispatch_request(audit.verb, path, headers)

        allowed_statuses = if audit.scopes_used.empty?
          [302, 303, 400, 404, 422]
        else
          [404]
        end

        unless allowed_statuses.include?(status)
          route_failures << RouteFailure.new(
            route: "#{audit.verb} #{audit.path} (#{audit.controller}##{audit.action})",
            target_model: target_model_name || "Unknown",
            expected: allowed_statuses,
            actual: status,
            message: "Expected HTTP #{allowed_statuses.join('/')} when attacker requests victim #{target_model_name} (id=#{target_id}), got HTTP #{status}"
          )
        end

        if victim_record
          reloaded = victim_record.class.find_by(id: victim_record.id)
          if reloaded.nil?
            route_failures << RouteFailure.new(
              route: "#{audit.verb} #{audit.path} (#{audit.controller}##{audit.action})",
              target_model: target_model_name,
              expected: "record intact",
              actual: "record deleted",
              message: "CROSS-TENANT DESTRUCTION: Victim #{target_model_name} (id=#{target_id}) was deleted by attacker request!"
            )
          elsif snapshot_record(reloaded) != snapshot_before
            route_failures << RouteFailure.new(
              route: "#{audit.verb} #{audit.path} (#{audit.controller}##{audit.action})",
              target_model: target_model_name,
              expected: "record unchanged",
              actual: "record mutated",
              message: "CROSS-TENANT MUTATION: Victim #{target_model_name} (id=#{target_id}) was modified by attacker request!"
            )
          end
        end

        Result.new(
          scoped_models_count: 0,
          probed_routes_count: 1,
          scope_failures: [],
          route_failures: route_failures
        )
      end

      def probe_all(victim:, attacker:, victim_records:, ui_auth:, api_auth: nil)
        scope_res = probe_model_scopes(victim: victim, attacker: attacker, victim_records: victim_records)
        route_res = probe_idor_routes(victim_records: victim_records, ui_auth: ui_auth, api_auth: api_auth)

        Result.new(
          scoped_models_count: scope_res.scoped_models_count,
          probed_routes_count: route_res.probed_routes_count,
          scope_failures: scope_res.scope_failures,
          route_failures: route_res.route_failures
        )
      end

      def self.collect_enforced_id_audits(registry = MechaTenant.registry, configuration = MechaTenant.configuration)
        static_result = Static.new(registry, configuration).audit
        static_result.action_audits.select do |audit|
          audit.status == :enforced && audit.path.include?(":id")
        end
      end

      private

      def normalize_records_map(records_hash)
        records_hash.each_with_object({}) do |(k, v), h|
          key = k.is_a?(Class) ? k.name.to_s : k.to_s
          h[key] = v
        end
      end

      def infer_target_model(audit, normalized_records)
        # 1. Check explicit tenant_scope(Model) used by the action
        audit.scopes_used.each do |scope_str|
          if scope_str =~ /\Atenant_scope\((.+)\)\z/
            model_name = Regexp.last_match(1)
            return model_name if normalized_records.key?(model_name)
          end
        end

        # 2. Check current_user.<association> used by the action
        tenant_root_class = @registry.tenant_root.safe_constantize
        if tenant_root_class && tenant_root_class.respond_to?(:reflect_on_association)
          audit.scopes_used.each do |scope_str|
            if scope_str =~ /\A#{Regexp.escape(@configuration.tenant_method.to_s)}\.([a-zA-Z0-9_]+)\z/
              assoc_name = Regexp.last_match(1).to_sym
              refl = tenant_root_class.reflect_on_association(assoc_name)
              if refl
                klass_name = refl.class_name.to_s
                return klass_name if normalized_records.key?(klass_name)
              end
            end
          end
        end

        # 3. Fallback to controller name singularized (e.g. Api::V1::EmailsController -> EmailMessage / EmailHandler)
        demodulized = audit.controller.sub(/Controller\z/, "").split("::").last.singularize
        return demodulized if normalized_records.key?(demodulized)

        nil
      end

      def snapshot_record(record)
        record.attributes.except("updated_at")
      end

      def dispatch_request(verb, path, headers = {})
        case verb.to_s.upcase
        when "GET", "*"
          @session.get path, headers: headers
        when "POST"
          @session.post path, headers: headers
        when "PATCH"
          @session.patch path, headers: headers
        when "PUT"
          @session.put path, headers: headers
        when "DELETE"
          @session.delete path, headers: headers
        when "HEAD"
          @session.head path, headers: headers
        else
          @session.get path, headers: headers
        end

        @session.response.status
      rescue ActionController::RoutingError, ActiveRecord::RecordNotFound
        404
      end
    end
  end
end
