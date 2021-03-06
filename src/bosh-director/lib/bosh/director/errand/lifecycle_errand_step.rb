module Bosh::Director
  class Errand::LifecycleErrandStep
    def initialize(runner, deployment_planner, name, instance, instance_group, skip_errand, keep_alive, deployment_name, logger)
      @runner = runner
      @deployment_planner = deployment_planner
      @errand_name = name
      @instance = instance
      @skip_errand = skip_errand
      @keep_alive = keep_alive
      @logger = logger
      instance_group_manager = Errand::InstanceGroupManager.new(@deployment_planner, instance_group, @logger)
      @errand_instance_updater = Errand::ErrandInstanceUpdater.new(instance_group_manager, @logger, @errand_name, deployment_name)
    end

    def prepare
      return if @skip_errand
      @errand_instance_updater.create_vms(@keep_alive)
    end

    def run(&checkpoint_block)
      if @skip_errand
        @logger.info('Skip running errand because since last errand run was successful and there have been no changes to job configuration')
        return Errand::Result.new(@errand_name, -1, 'no configuration changes', '', nil)
      end

      begin
        result = nil
        @errand_instance_updater.with_updated_instances(@keep_alive) do
          @logger.info('Starting to run errand')
          result = @runner.run(@instance, &checkpoint_block)
        end
        result
      ensure
        @deployment_planner.template_blob_cache.clean_cache!
      end
    end

    def ignore_cancellation?
      @errand_instance_updater && @errand_instance_updater.ignore_cancellation?
    end
  end
end
