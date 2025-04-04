==========
  kw env
==========
.. _kw-env:

.. contents::
   :depth: 1
   :local:
   :backlinks: none

.. highlight:: console

Introduction
------------

Inspired by Ruby RVM and Python Env, kw has a feature that enables developers
to create environments for their context and quickly switches between them. For
example, in the same kernel, the developer might want to work with ARM and X86,
and kw env can be an excellent way to switch between these two contexts.

When kw creates a new env, it isolates::

 * The .config file
 * All kw config
 * Build files

As a result, env feature must interoperate with these features::

 * Build
 * Deploy
 * Kernel config

Create a new env
----------------

Let's say that you have a fresh new kernel ready to be compiled, and you
started your kw config by using::

  kw init

Now you want to create a new env to maintain the specific configuration you can
use::

  kw env --create <ENV_NAME>

For example::

 kw env --create X86_64_CONFIG_TO_TEST_MACHINE_Y

When you create a new env, it will instantiate the current config to the new
env. Every change you make in the kw configurations will be contained in the
current config. For example, you can change your build or remote options, and
after that, create a new env::

 kw env --create X86_32_CONFIG_TO_TEST_MACHINE_P

Switch between envs
-------------------

Let's say that you want to switch from one config to another, you can just use::

 kw env --use X86_32_CONFIG_TO_TEST_MACHINE_P

If you want to check if everything looks correct, you can use::

 kw config --show

How to customize your bash terminal to display the current environment
----------------------------------------------------------------------

This feature lets users view the current kw environment (if you have one) in their
bash terminal via the PS1 variable. It is especially useful when working with multiple
kw envs, as it helps you stay aware of the context you are working in.

To enable this functionality, follow these steps:

If you did not install kw yet, run the below command; otherwise, go to the next step::

  ./setup -i

Enable the functionality to show the current environment
in the bash terminal by running the following command::

  ./setup -s

Once enabled, you need to add the following line to the .bashrc file::

  PS1="${PS1/\\$/}" && PS1+="\$(kw_get_current_env_name)$ "

.. note::
    If you have modified the PS1 variable in the .bashrc file, you will need to adapt
    it to work correctly. You can simply call the ``kw_get_current_env_name`` function
    on PS1 to display the current environment being used in kworkflow.
