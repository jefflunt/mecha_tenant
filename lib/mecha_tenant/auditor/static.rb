# frozen_string_literal: true

require "prism"
require "set"

module MechaTenant
  module Auditor
    class Static
      Violation = Struct.new(
        :file,
        :line,
        :controller,
        :method_name,
        :model,
        :kind,
        :message,
        :snippet,
        keyword_init: true
      )

      ActionAudit = Struct.new(
        :verb,
        :path,
        :controller,
        :action,
        :status,
        :scopes_used,
        :skip_reason,
        :route_roles,
        keyword_init: true
      )

      Result = Struct.new(
        :mapped_models,
        :unmapped_models,
        :dead_models,
        :missing_scopes,
        :dead_skip_rules,
        :violations,
        :action_audits,
        keyword_init: true
      ) do
        def success?
          unmapped_models.empty? &&
            dead_models.empty? &&
            missing_scopes.empty? &&
            dead_skip_rules.empty? &&
            violations.empty?
        end
      end

      def initialize(registry = MechaTenant.registry, configuration = MechaTenant.configuration)
        @registry = registry
        @configuration = configuration
      end

      def audit
        ensure_models_loaded!

        actual_models = discover_application_models
        registered_models = @registry.models.keys

        mapped_models = []
        unmapped_models = []

        actual_models.sort.each do |model_name|
          if @registry.registered?(model_name)
            mapped_models << @registry.model_entry(model_name)
          else
            unmapped_models << model_name
          end
        end

        dead_models = (registered_models - actual_models).sort

        missing_scopes = check_scope_parity
        dead_skip_rules = []
        violations = []
        method_metadata_by_controller = {}

        controller_files.each do |file_path|
          file_result = analyze_controller_file(file_path)
          dead_skip_rules.concat(file_result[:dead_skip_rules])
          violations.concat(file_result[:violations])
          file_result[:controllers].each do |ctrl_name, meta|
            method_metadata_by_controller[ctrl_name] = meta
          end
        end

        action_audits = build_route_action_audits(method_metadata_by_controller, violations)

        Result.new(
          mapped_models: mapped_models,
          unmapped_models: unmapped_models,
          dead_models: dead_models,
          missing_scopes: missing_scopes,
          dead_skip_rules: dead_skip_rules,
          violations: violations,
          action_audits: action_audits
        )
      end

      # Analyze a single Ruby source string for a given controller class (useful for unit testing)
      def audit_source(source, controller_class:, file_path: "(inline)")
        parsed = Prism.parse(source)
        lines = source.lines
        known_models = Set.new(@registry.models.keys)
        known_models << @configuration.base_model_class.to_s if @configuration.base_model_class

        analyze_controller_ast(
          parsed.value,
          lines: lines,
          file_path: file_path,
          known_models: known_models,
          explicit_controller_class: controller_class
        )
      end

      private

      def ensure_models_loaded!
        if defined?(Rails) && Rails.respond_to?(:application) && Rails.application
          Rails.application.eager_load!
        end
      end

      def discover_application_models
        base_class_name = @configuration.base_model_class.to_s
        base_class = base_class_name.safe_constantize
        return [] unless base_class

        base_class.descendants
                  .reject(&:abstract_class?)
                  .select { |klass| klass.name.present? && !klass.name.include?("#<") }
                  .select { |klass| app_model_class?(klass) }
                  .map(&:name)
                  .uniq
      end

      def app_model_class?(klass)
        return true unless defined?(Rails) && Rails.respond_to?(:root) && Rails.root

        const_loc = Object.const_source_location(klass.name)
        return true if const_loc.nil?

        file_path = const_loc.first.to_s
        file_path.start_with?(Rails.root.join("app/models").to_s)
      end

      def check_scope_parity
        errors = []
        @registry.models.each do |model_name, entry|
          if entry[:classification] == :tenant && !@registry.scope_defined?(model_name)
            errors << "Tenant model '#{model_name}' is missing a `define_scope` declaration in MechaTenant configuration"
          elsif entry[:classification] == :global && @registry.scope_defined?(model_name)
            errors << "Global model '#{model_name}' must not have a `define_scope` declaration in MechaTenant configuration"
          end
        end
        errors
      end

      def controller_files
        paths = Array(@configuration.controller_paths)
        paths.flat_map do |dir|
          Dir.glob(File.join(dir.to_s, "**", "*_controller.rb")).sort
        end.uniq
      end

      def analyze_controller_file(file_path)
        source = File.read(file_path)
        lines = source.lines
        parsed = Prism.parse(source)
        known_models = Set.new(@registry.models.keys)
        known_models << @configuration.base_model_class.to_s if @configuration.base_model_class

        analyze_controller_ast(
          parsed.value,
          lines: lines,
          file_path: relative_path(file_path),
          known_models: known_models
        )
      end

      def analyze_controller_ast(root_node, lines:, file_path:, known_models:, explicit_controller_class: nil)
        violations = []
        dead_skip_rules = []
        controllers_meta = {}

        class_entries = extract_controller_classes(root_node)

        class_entries.each do |entry|
          ctrl_name = explicit_controller_class ? explicit_controller_class.name.to_s : entry[:name]
          ctrl_klass = explicit_controller_class || ctrl_name.safe_constantize
          class_node = entry[:node]

          methods = extract_instance_methods(class_node)
          method_names = methods.keys.map(&:to_s)

          if ctrl_klass && ctrl_klass.respond_to?(:own_tenant_enforcement_rules)
            dead_skip_rules.concat(check_dead_skip_rules(ctrl_klass, ctrl_name, method_names, file_path))
          end

          # Determine which methods are enforced vs skipped
          enforced_methods, skipped_methods = partition_methods(ctrl_klass, methods)

          scopes_by_method = {}
          calls_by_method = {}

          methods.each do |m_name, m_node|
            scan = scan_method_node(
              m_node,
              lines: lines,
              file_path: file_path,
              ctrl_name: ctrl_name,
              method_name: m_name,
              known_models: known_models
            )
            scopes_by_method[m_name] = scan[:scopes_used]
            calls_by_method[m_name] = scan[:local_calls]

            if enforced_methods.include?(m_name)
              violations.concat(scan[:violations])
            end
          end

          controllers_meta[ctrl_name] = {
            klass: ctrl_klass,
            methods: methods.keys,
            enforced_methods: enforced_methods,
            skipped_methods: skipped_methods,
            scopes_by_method: scopes_by_method,
            calls_by_method: calls_by_method
          }
        end

        {
          violations: violations,
          dead_skip_rules: dead_skip_rules,
          controllers: controllers_meta
        }
      end

      def check_dead_skip_rules(ctrl_klass, ctrl_name, defined_methods, file_path)
        dead = []
        action_methods = Set.new(ctrl_klass.action_methods.map(&:to_s)) + Set.new(defined_methods)

        ctrl_klass.own_tenant_enforcement_rules.each do |rule|
          Array(rule[:only]).each do |act|
            unless action_methods.include?(act.to_s)
              dead << {
                controller: ctrl_name,
                action: act.to_s,
                file: file_path,
                message: "#{ctrl_name} skips non-existent action ':#{act}'"
              }
            end
          end
          Array(rule[:except]).each do |act|
            unless action_methods.include?(act.to_s)
              dead << {
                controller: ctrl_name,
                action: act.to_s,
                file: file_path,
                message: "#{ctrl_name} excepts non-existent action ':#{act}'"
              }
            end
          end
        end

        dead
      end

      def partition_methods(ctrl_klass, methods_hash)
        tenant_method_name = @configuration.tenant_method.to_s
        enforced = Set.new
        skipped = Set.new

        public_actions = ctrl_klass ? Set.new(ctrl_klass.action_methods.map(&:to_s)) : Set.new(methods_hash.keys)

        methods_hash.each_key do |m_name|
          if m_name == tenant_method_name
            skipped << m_name
          elsif ctrl_klass && ctrl_klass.respond_to?(:tenant_enforcement_skipped_for?)
            if public_actions.include?(m_name)
              if ctrl_klass.tenant_enforcement_skipped_for?(m_name)
                skipped << m_name
              else
                enforced << m_name
              end
            else
              # Private/helper method: enforced if any public action on this controller is enforced,
              # or if the controller itself does not have a blanket skip rule.
              blanket_skip = ctrl_klass.tenant_enforcement_rules.any? { |r| r[:only].nil? && r[:except].nil? }
              if blanket_skip
                skipped << m_name
              else
                enforced << m_name
              end
            end
          else
            enforced << m_name
          end
        end

        [enforced, skipped]
      end

      def scan_method_node(method_node, lines:, file_path:, ctrl_name:, method_name:, known_models:)
        violations = []
        scopes_used = Set.new
        local_calls = Set.new

        tenant_method_sym = @configuration.tenant_method.to_sym

        walk_ast(method_node, nil) do |node, parent|
          case node
          when Prism::CallNode
            # Track calls to tenant_scope(Model)
            if node.receiver.nil? && node.name == :tenant_scope
              arg = node.arguments&.arguments&.first
              model_name = extract_constant_name(arg)
              if model_name
                if @registry.global_model?(model_name)
                  line_no = node.location.start_line
                  violations << Violation.new(
                    file: file_path,
                    line: line_no,
                    controller: ctrl_name,
                    method_name: method_name,
                    model: model_name,
                    kind: :global_model_in_tenant_scope,
                    message: "Global model '#{model_name}' cannot be passed to tenant_scope(#{model_name})",
                    snippet: lines[line_no - 1].to_s.strip
                  )
                elsif !@registry.registered?(model_name)
                  line_no = node.location.start_line
                  violations << Violation.new(
                    file: file_path,
                    line: line_no,
                    controller: ctrl_name,
                    method_name: method_name,
                    model: model_name,
                    kind: :unregistered_model_in_tenant_scope,
                    message: "Unregistered model '#{model_name}' passed to tenant_scope(#{model_name})",
                    snippet: lines[line_no - 1].to_s.strip
                  )
                else
                  scopes_used << "tenant_scope(#{model_name})"
                end
              end
            elsif call_on_tenant_root?(node, tenant_method_sym)
              scopes_used << "#{tenant_method_sym}.#{node.name}"
            elsif node.receiver.nil?
              local_calls << node.name.to_s
            end

          when Prism::ConstantReadNode, Prism::ConstantPathNode
            # Skip if this node is the child of an outer ConstantPathNode (we evaluate the outermost path or check parent)
            if parent.is_a?(Prism::ConstantPathNode)
              # Wait: if parent is EmailMessage::CATEGORIES, then `node` is `EmailMessage` and `parent` is `EmailMessage::CATEGORIES`.
              # Neither `EmailMessage::CATEGORIES` (not a model) nor `EmailMessage` (namespace of a constant) is a model query!
              next
            end

            const_name = extract_constant_name(node)
            next unless const_name && known_models.include?(const_name)

            # Allowed if directly inside tenant_scope(Model) arguments
            if inside_tenant_scope_arg?(node, parent)
              next
            end

            line_no = node.location.start_line
            violations << Violation.new(
              file: file_path,
              line: line_no,
              controller: ctrl_name,
              method_name: method_name,
              model: const_name,
              kind: :naked_model_reference,
              message: "Direct reference to model '#{const_name}' in #{ctrl_name}##{method_name}; use `tenant_scope(#{const_name})` or `#{tenant_method_sym}` association, or declare `skip_tenant_enforcement!`",
              snippet: lines[line_no - 1].to_s.strip
            )
          end
        end

        {
          violations: violations,
          scopes_used: scopes_used.to_a,
          local_calls: local_calls.to_a
        }
      end

      def inside_tenant_scope_arg?(node, parent)
        return false unless parent.is_a?(Prism::ArgumentsNode)

        # We check in walk_ast by passing the enclosing CallNode when parent is ArgumentsNode
        false
      end

      def call_on_tenant_root?(call_node, tenant_method_sym)
        recv = call_node.receiver
        return false unless recv.is_a?(Prism::CallNode)
        return false unless recv.receiver.nil? && recv.name == tenant_method_sym

        tenant_klass = @registry.tenant_root.to_s.safe_constantize
        if tenant_klass && tenant_klass.respond_to?(:reflect_on_association)
          !tenant_klass.reflect_on_association(call_node.name).nil?
        else
          true
        end
      end

      def walk_ast(node, parent, enclosing_call = nil, &block)
        return if node.nil?

        if node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)
          # Check if directly passed as the argument to `tenant_scope(...)`
          if parent.is_a?(Prism::ArgumentsNode) &&
             enclosing_call.is_a?(Prism::CallNode) &&
             enclosing_call.receiver.nil? &&
             enclosing_call.name == :tenant_scope
            return
          end
        end

        yield(node, parent)

        next_enclosing_call = node.is_a?(Prism::CallNode) ? node : enclosing_call

        node.compact_child_nodes.each do |child|
          walk_ast(child, node, next_enclosing_call, &block)
        end
      end

      def extract_constant_name(node)
        case node
        when Prism::ConstantReadNode
          node.name.to_s
        when Prism::ConstantPathNode
          node.slice.sub(/\A::/, "")
        else
          nil
        end
      end

      def extract_controller_classes(root_node, namespace_prefix = [])
        results = []
        return results if root_node.nil?

        root_node.compact_child_nodes.each do |child|
          case child
          when Prism::ModuleNode
            mod_name = extract_constant_name(child.constant_path)
            results.concat(extract_controller_classes(child.body, namespace_prefix + [mod_name]))
          when Prism::ClassNode
            cls_name = extract_constant_name(child.constant_path)
            full_name = (namespace_prefix + [cls_name]).compact.join("::")
            # Check if nested classes exist inside (exclude test double classes if any, or include controller classes)
            if full_name.end_with?("Controller")
              results << { name: full_name, node: child }
            end
            results.concat(extract_controller_classes(child.body, namespace_prefix + [cls_name]))
          else
            results.concat(extract_controller_classes(child, namespace_prefix))
          end
        end

        results
      end

      def extract_instance_methods(class_node)
        methods = {}
        return methods unless class_node.body

        class_node.body.compact_child_nodes.each do |node|
          if node.is_a?(Prism::DefNode) && node.receiver.nil?
            methods[node.name.to_s] = node
          end
        end

        methods
      end

      def build_route_action_audits(method_metadata_by_controller, violations)
        return [] unless defined?(Rails) && Rails.respond_to?(:application) && Rails.application

        routes = Rails.application.routes.routes.map do |r|
          ActionDispatch::Routing::RouteWrapper.new(r)
        end.reject(&:internal?)

        audits = []
        seen = Set.new

        routes.each do |r|
          next if r.engine?

          ctrl_path = r.controller.presence
          action_name = r.action.presence
          next unless ctrl_path && action_name
          next if ctrl_path.start_with?("rails/", "active_storage/", "action_mailbox/", "turbo/")

          verb = r.verb.to_s.empty? ? "*" : r.verb.to_s.upcase
          path = r.path.sub("(.:format)", "")
          dedup_key = [verb, path, ctrl_path, action_name]
          next if seen.include?(dedup_key)
          seen << dedup_key

          ctrl_class_name = "#{ctrl_path.camelize}Controller"
          ctrl_klass = ctrl_class_name.safe_constantize
          meta = method_metadata_by_controller[ctrl_class_name]

          skip_reason = if ctrl_klass && ctrl_klass.respond_to?(:tenant_enforcement_reason_for)
            ctrl_klass.tenant_enforcement_reason_for(action_name)
          end

          action_violations = violations.select do |v|
            v.controller == ctrl_class_name && v.method_name == action_name
          end

          scopes = resolve_action_scopes(meta, action_name)

          status = if action_violations.any?
            :violation
          elsif skip_reason
            :skipped
          else
            :enforced
          end

          route_roles = if @configuration.route_classifier
            @configuration.route_classifier.call(verb, path)
          end

          audits << ActionAudit.new(
            verb: verb,
            path: path,
            controller: ctrl_class_name,
            action: action_name,
            status: status,
            scopes_used: scopes,
            skip_reason: skip_reason,
            route_roles: route_roles
          )
        end

        audits
      end

      def resolve_action_scopes(meta, action_name)
        return [] unless meta

        scopes = Set.new(meta[:scopes_by_method][action_name] || [])

        # Include scopes from before_actions or private helper methods called by this action
        called_helpers = meta[:calls_by_method][action_name] || []
        called_helpers.each do |helper_name|
          (meta[:scopes_by_method][helper_name] || []).each { |s| scopes << s }
        end

        # Also check controller before_action filters if available
        klass = meta[:klass]
        if klass && klass.respond_to?(:_process_action_callbacks)
          klass._process_action_callbacks.each do |cb|
            next unless cb.kind == :before && cb.filter.is_a?(Symbol)
            filter_name = cb.filter.to_s
            (meta[:scopes_by_method][filter_name] || []).each { |s| scopes << s }
          end
        end

        scopes.to_a.sort
      end

      def relative_path(path)
        if defined?(Rails) && Rails.respond_to?(:root) && Rails.root
          path.to_s.sub(/\A#{Regexp.escape(Rails.root.to_s)}\/?/, "")
        else
          path.to_s
        end
      end
    end
  end
end
